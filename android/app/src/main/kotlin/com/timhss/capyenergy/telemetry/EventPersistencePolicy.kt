package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.VehicleProfile

/**
 * Which telemetry events earn a row in `telemetry_events` (issue 226).
 *
 * Only three kinds persist:
 *  - lifecycle and diagnostics — anything whose type is not
 *    [TelemetryEventType.SIGNAL_UPDATED]: the session transitions
 *    (`TRIP_*`, `CHARGE_*`, `VEHICLE_ACTIVITY_CHANGED`) and the signal
 *    complaints (`SIGNAL_ERROR`, `SIGNAL_UNAVAILABLE`);
 *  - session-narrative signals ([VehicleProfile.sessionEventKeys]) even
 *    before their session opens, because `backStampSession` claims
 *    unstamped narrative rows and the gear change that starts a drive is
 *    written before the trip row exists;
 *  - anything already stamped with a session id.
 *
 * Everything else — odometer ticks, pedal presses, steering-wheel keys,
 * door latches while parked — stays in the in-memory recent-events buffer
 * only. The `everyChangeIsAnEvent` declarations still fire, so the live UI
 * keeps its feed; only the database write is filtered.
 */
class EventPersistencePolicy(private val profile: VehicleProfile) {
    fun shouldPersist(event: TelemetryEvent): Boolean = when {
        event.type != TelemetryEventType.SIGNAL_UPDATED -> true
        event.signalId != null && profile.isSessionEvent(event.signalId) -> true
        event.sessionId != null -> true
        else -> false
    }
}
