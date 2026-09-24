package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import com.timhss.capyenergy.telemetry.db.SessionEntity

internal fun SessionEntity.tripPowerIntegral(): TripPowerIntegral? {
    val traction = rollupTractionWh ?: return null
    val regen = rollupRegenWh ?: return null
    val aux = rollupAuxiliaryWh ?: return null
    val seconds = rollupIntegratedSeconds ?: return null
    return TripPowerIntegral(
        packWh = traction - regen + aux,
        tractionWh = traction,
        regeneratedWh = regen,
        auxiliaryWh = aux,
        integratedSeconds = seconds
    )
}

internal fun SessionEntity.tripEnergyBreakdown(): TripEnergyBreakdown? =
    tripPowerIntegral()?.toBreakdown()

internal object SessionAggregateCalculator {
    fun applyFold(
        session: SessionEntity,
        rollup: EnergyRollup,
        sweep: SessionSampleSweep
    ): SessionEntity {
        val accumulator = SessionAggregateAccumulator()
        sweep.forEach(accumulator::add)
        val firstSoc = accumulator.firstSoc()
        val lastSoc = accumulator.lastSoc()
        val minSoc = accumulator.minSoc() ?: session.minSocPercent
        val maxSoc = accumulator.maxSoc() ?: session.maxSocPercent
        val startSoc = session.startSocPercent ?: firstSoc
        val endSoc = session.endSocPercent ?: lastSoc

        val agrees = when (session.kind) {
            "TRIP" -> TelemetryEnergy.integralAgreesWithSoc(
                integralWh = rollup.netPackWh,
                startSoc = startSoc?.toDouble(),
                endSoc = endSoc?.toDouble()
            )
            "CHARGE" -> {
                val start = startSoc?.toDouble()
                val end = endSoc?.toDouble()
                if (start != null && end != null && kotlin.math.abs(end - start) >= TelemetryEnergy.SOC_NOISE_PERCENT && rollup.deliveredWh > 0.0) {
                    (end > start) == (rollup.deliveredWh > 0.0)
                } else null
            }
            else -> null
        }
        val agreementStr = when (agrees) {
            true -> "agrees"
            false -> "contradicts"
            null -> "unconfirmed"
        }

        val ambientMean = accumulator.meanAmbientTempC()

        return session.copy(
            rollupDistanceKm = rollup.distanceKm,
            rollupTractionWh = rollup.tractionWh,
            rollupRegenWh = rollup.regenWh,
            rollupAuxiliaryWh = rollup.auxiliaryWh,
            rollupClimateWh = rollup.climateWh,
            rollupDeliveredWh = rollup.deliveredWh,
            rollupIntegratedSeconds = if (session.kind == "CHARGE") rollup.deliveredIntegratedSeconds else rollup.integratedSeconds,
            startSocPercent = startSoc,
            endSocPercent = endSoc,
            minSocPercent = minSoc,
            maxSocPercent = maxSoc,
            socAgreesWithIntegral = agreementStr,
            startAmbientTempC = session.startAmbientTempC ?: accumulator.firstAmbientTempC(),
            endAmbientTempC = session.endAmbientTempC ?: accumulator.lastAmbientTempC(),
            meanAmbientTempC = session.meanAmbientTempC ?: ambientMean,
            updatedAtUtcMillis = System.currentTimeMillis()
        )
    }

    fun applyFold(
        session: SessionEntity,
        rollup: EnergyRollup,
        samples: List<SessionAggregateSampleRow>
    ): SessionEntity = applyFold(
        session,
        rollup,
        SessionSampleSweep { consume -> samples.forEach(consume) }
    )
}
