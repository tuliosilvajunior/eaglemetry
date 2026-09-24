package com.timhss.capyenergy.profile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What may appear on a session's event list.
 *
 * The list is read by a person, so the set is a product statement and it
 * belongs to the profile beside the other things that describe this vehicle.
 * These assertions exist so that widening it stays a deliberate act: on
 * 2026-08-21 one recorded 17-minute trip produced 57 odometer events and 32
 * activity changes against 5 rows that describe the drive.
 */
class SessionEventKeysTest {

    @Test
    fun whatAPersonRecognisesIsOnTheList() {
        assertTrue(GeelyProfile.isSessionEvent(SignalKey.GEAR))
        assertTrue(GeelyProfile.isSessionEvent(SignalKey.HEADLIGHTS_SWITCH))
        assertTrue(GeelyProfile.isSessionEvent(SignalKey.ADAS_ACC_CRUISE_MODE))
        assertTrue(GeelyProfile.isSessionEvent(SignalKey.EV_CHARGE_STATE))
        assertTrue(GeelyProfile.isSessionEvent(SignalKey.EV_CHARGE_PLUG_TYPE))
    }

    @Test
    fun aStateWithACurveIsNotAnEvent() {
        // Both have their own series in `sample`, and both arrive by the
        // dozen. A list holding them is a log, not a story.
        assertFalse(GeelyProfile.isSessionEvent(SignalKey.ODOMETER))
        assertFalse(GeelyProfile.isSessionEvent(SignalKey.HV_BATTERY_SOC))
        assertFalse(GeelyProfile.isSessionEvent(SignalKey.VEHICLE_SPEED))
    }

    @Test
    fun everyDeclaredKeyIsOneTheVehicleCanAnswer() {
        // A key that no transport reaches would be a line on the list that
        // never appears, and nothing would ever say so.
        val reachable = GeelyProfile.propertySignals.map { it.signalId }.toSet() +
            GeelyProfile.busSignals.keys
        for (key in GeelyProfile.sessionEventKeys) {
            assertTrue(
                "$key is on the session event list but no transport reaches it",
                key in reachable
            )
        }
    }
}
