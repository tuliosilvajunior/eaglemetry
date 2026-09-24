package com.timhss.capyenergy.telemetry

/**
 * Frame persistence cadence (PRD §12.3): 1 Hz baseline; 1 frame per 5 s once a
 * charge session is past its ramp-up window and power is stable. Discrete
 * transitions (gear, charge state, plug) always flush immediately; continuous
 * signals wait for the next due tick since they are sampled into frames anyway.
 */
class FrameCadence {
    private var lastFrameElapsedNanos = 0L
    private var lastDiscreteSignature = ""
    private var chargeSessionId: String? = null
    private var chargeSessionStartNanos = 0L
    private var lastPersistedPowerKw: Float? = null

    @Synchronized
    fun shouldPersist(
        nowNanos: Long,
        discreteSignature: String,
        session: ActiveFrameSession?,
        chargePowerKw: Float?
    ): Boolean {
        if (lastDiscreteSignature.isNotBlank() && discreteSignature != lastDiscreteSignature) {
            return true
        }
        return nowNanos - lastFrameElapsedNanos >= intervalNanos(nowNanos, session, chargePowerKw)
    }

    @Synchronized
    fun onPersisted(nowNanos: Long, discreteSignature: String, powerKw: Float?) {
        lastFrameElapsedNanos = nowNanos
        lastDiscreteSignature = discreteSignature
        lastPersistedPowerKw = powerKw
    }

    @Synchronized
    fun isDiscreteTransition(discreteSignature: String): Boolean =
        lastDiscreteSignature.isNotBlank() && discreteSignature != lastDiscreteSignature

    @Synchronized
    fun reset() {
        lastFrameElapsedNanos = 0L
        lastDiscreteSignature = ""
        chargeSessionId = null
        chargeSessionStartNanos = 0L
        lastPersistedPowerKw = null
    }

    private fun intervalNanos(
        nowNanos: Long,
        session: ActiveFrameSession?,
        chargePowerKw: Float?
    ): Long {
        if (session?.type != CHARGE_SESSION_TYPE) {
            chargeSessionId = null
            return BASE_INTERVAL_NANOS
        }
        if (session.id != chargeSessionId) {
            chargeSessionId = session.id
            chargeSessionStartNanos = nowNanos
        }
        if (nowNanos - chargeSessionStartNanos < CHARGE_RAMP_NANOS) return BASE_INTERVAL_NANOS
        val power = chargePowerKw ?: return BASE_INTERVAL_NANOS
        val lastPower = lastPersistedPowerKw ?: return BASE_INTERVAL_NANOS
        return if (kotlin.math.abs(power - lastPower) >= CHARGE_POWER_DELTA_KW) {
            BASE_INTERVAL_NANOS
        } else {
            CHARGE_STABLE_INTERVAL_NANOS
        }
    }

    companion object {
        const val CHARGE_SESSION_TYPE = "CHARGE"
        const val BASE_INTERVAL_NANOS = 1_000_000_000L
        const val CHARGE_STABLE_INTERVAL_NANOS = 5_000_000_000L
        const val CHARGE_RAMP_NANOS = 60_000_000_000L
        const val CHARGE_POWER_DELTA_KW = 0.5f
    }
}
