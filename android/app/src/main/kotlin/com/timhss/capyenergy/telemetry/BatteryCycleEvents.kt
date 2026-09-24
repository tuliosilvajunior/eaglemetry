package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.BatteryCycleLedger.Event
import com.timhss.capyenergy.telemetry.BatteryCycleLedger.EventKind
import com.timhss.capyenergy.telemetry.db.SessionCostEntity
import com.timhss.capyenergy.telemetry.db.SessionEntity

/**
 * Turns the unified session table into the one time-ordered stream the ledger folds.
 */
object BatteryCycleEvents {

    fun build(
        sessions: List<SessionEntity>,
        capacityFallbackWh: Double? = null,
        /**
         * Charge prices, keyed by session id. A price is an annotation row
         * since slice 6, so the ledger reads it from here rather than from
         * the session's dead cost columns.
         */
        costs: Map<String, SessionCostEntity> = emptyMap()
    ): List<Event> {
        val events = ArrayList<Event>(sessions.size)
        sessions.forEach { s ->
            when (s.kind) {
                "TRIP" -> tripEvent(s, capacityFallbackWh)?.let(events::add)
                "CHARGE" -> chargeEvent(s, capacityFallbackWh, costs[s.id])?.let(events::add)
                "PARKED" -> parkedEvent(s, capacityFallbackWh)?.let(events::add)
            }
        }
        return events.sortedWith(compareBy({ it.startUtcMillis }, { it.endUtcMillis }))
    }

    private fun tripEvent(trip: SessionEntity, fallbackWh: Double?): Event? {
        val start = trip.startSocPercent?.toDouble() ?: return null
        val end = trip.endSocPercent?.toDouble() ?: return null
        val endedAt = trip.endedAtUtcMillis ?: return null
        return Event(
            kind = EventKind.TRIP,
            sessionId = trip.id,
            startUtcMillis = trip.startedAtUtcMillis,
            endUtcMillis = endedAt,
            startSoc = start,
            endSoc = end,
            capacityWh = fallbackWh,
            distanceKm = odometerDistanceKm(trip)
        )
    }

    private fun chargeEvent(charge: SessionEntity, fallbackWh: Double?, cost: SessionCostEntity?): Event? {
        val start = charge.startSocPercent?.toDouble() ?: return null
        val end = charge.endSocPercent?.toDouble() ?: return null
        val startedAt = charge.chargeStartedAtUtcMillis ?: charge.startedAtUtcMillis
        val endedAt = charge.chargeEndedAtUtcMillis
            ?: charge.plugDisconnectedAtUtcMillis
            ?: charge.endedAtUtcMillis
            ?: return null
        return Event(
            kind = EventKind.CHARGE,
            sessionId = charge.id,
            startUtcMillis = startedAt,
            endUtcMillis = endedAt,
            startSoc = start,
            endSoc = end,
            capacityWh = fallbackWh,
            costPerKwh = effectivePricePerKwh(charge, cost, fallbackWh),
            costCurrency = cost?.costCurrency ?: charge.costCurrency
        )
    }

    private fun parkedEvent(session: SessionEntity, fallbackWh: Double?): Event? {
        val start = session.startSocPercent?.toDouble() ?: return null
        val end = (session.endSocPercent ?: session.lastSoc)?.toDouble() ?: return null
        val endedAt = session.endedAtUtcMillis ?: return null
        return Event(
            kind = EventKind.PARKED,
            sessionId = session.id,
            startUtcMillis = session.startedAtUtcMillis,
            endUtcMillis = endedAt,
            startSoc = start,
            endSoc = end,
            capacityWh = fallbackWh
        )
    }

    private fun effectivePricePerKwh(
        charge: SessionEntity,
        cost: SessionCostEntity?,
        fallbackWh: Double?
    ): Double? {
        val paid = cost?.paidAmount ?: charge.paidAmount
        if (paid != null && paid > 0.0) {
            val energyKwh = chargedEnergyKwh(charge, fallbackWh)
            if (energyKwh != null && energyKwh > 0.0) return paid / energyKwh
        }
        return (cost?.costPerKwh ?: charge.costPerKwh)?.takeIf { it > 0.0 }
    }

    private fun chargedEnergyKwh(charge: SessionEntity, fallbackWh: Double?): Double? {
        val start = charge.startSocPercent?.toDouble() ?: return null
        val end = charge.endSocPercent?.toDouble() ?: return null
        val capacityWh = fallbackWh?.takeIf { it > 0.0 } ?: return null
        val gain = end - start
        if (gain <= 0.0) return null
        return gain / 100.0 * (capacityWh / 1000.0)
    }

    private fun odometerDistanceKm(trip: SessionEntity): Double? {
        val start = trip.startOdometerKm ?: return null
        val end = trip.endOdometerKm ?: return null
        val distance = (end - start).toDouble()
        return distance.takeIf { it >= 0.0 }
    }
}
