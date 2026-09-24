package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.SignalKey

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// Issue 226: the persistence bar an event must clear to reach
/// `telemetry_events`. The observable seam is the predicate; the buffer and
/// the database live in [EventRepository], which delegates to exactly this.
class EventPersistencePolicyTest {
    private val policy = EventPersistencePolicy(GeelyProfile)

    private fun event(
        type: TelemetryEventType,
        signalId: SignalKey? = null,
        sessionId: String? = null
    ) = TelemetryEvent(
        id = "e-1",
        type = type,
        timestamp = SignalTimestamp(0L, 0L, null, TimestampAccuracy.RECEIVED_EVENT, 0L),
        signalId = signalId,
        value = "1",
        previousValue = null,
        quality = SignalQuality.MEASURED,
        source = SignalSource.CAN_BRIDGE,
        details = "",
        sessionId = sessionId
    )

    @Test
    fun `a narrative signal persists even before its session opens`() {
        // The gear change that starts a drive is written before the trip row
        // exists and is claimed later by backStampSession.
        assertTrue(policy.shouldPersist(event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.GEAR)))
        assertTrue(
            policy.shouldPersist(event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.EV_CHARGE_STATE))
        )
    }

    @Test
    fun `a narrative signal inside its session persists`() {
        assertTrue(
            policy.shouldPersist(
                event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.GEAR, sessionId = "trip-1")
            )
        )
    }

    @Test
    fun `continuous signal churn does not persist`() {
        assertFalse(policy.shouldPersist(event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.ODOMETER)))
        assertFalse(
            policy.shouldPersist(event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.BRAKE_PEDAL))
        )
        assertFalse(
            policy.shouldPersist(event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.HV_BATTERY_SOC))
        )
    }

    @Test
    fun `parked hardware chatter does not persist`() {
        assertFalse(
            policy.shouldPersist(event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.CLIMATE_ON))
        )
        assertFalse(
            policy.shouldPersist(event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.BLOWER_LEVEL))
        )
    }

    @Test
    fun `diagnostics persist for any signal`() {
        assertTrue(
            policy.shouldPersist(event(TelemetryEventType.SIGNAL_ERROR, SignalKey.HV_BATTERY_VOLTAGE))
        )
        assertTrue(
            policy.shouldPersist(
                event(TelemetryEventType.SIGNAL_UNAVAILABLE, SignalKey.OUTSIDE_TEMPERATURE)
            )
        )
    }

    @Test
    fun `lifecycle transitions persist without a signal`() {
        assertTrue(policy.shouldPersist(event(TelemetryEventType.TRIP_STARTED)))
        assertTrue(policy.shouldPersist(event(TelemetryEventType.TRIP_ENDED)))
        assertTrue(policy.shouldPersist(event(TelemetryEventType.CHARGE_STARTED)))
        assertTrue(policy.shouldPersist(event(TelemetryEventType.VEHICLE_ACTIVITY_CHANGED)))
    }

    @Test
    fun `anything already stamped with a session persists`() {
        // Belt for rows that reach the store stamped by a path this policy
        // does not know about; an orphan the session later claims keeps its
        // narrative path, so this branch never has to fire for those.
        assertTrue(
            policy.shouldPersist(
                event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.ODOMETER, sessionId = "trip-1")
            )
        )
    }
}
