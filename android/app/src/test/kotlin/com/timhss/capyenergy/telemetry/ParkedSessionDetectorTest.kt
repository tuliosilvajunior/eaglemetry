package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.profile.GeelyProperties
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ParkedSessionDetectorTest {

    private class FakeParkedSessionStore : ParkedSessionStore {
        var openSession: SessionEntity? = null
        var createdCount = 0
        var closedCount = 0
        var updateLastSocCount = 0
        var lastCloseReason: String? = null

        override fun latestOpenParkedSession(): SessionEntity? = openSession

        override fun createParkedSession(
            startedAt: SignalTimestamp,
            startSoc: Float?,
            startAmbientTempC: Float?,
            parkingMode: Int?,
            status: String
        ): String {
            createdCount++
            val id = "parked-$createdCount"
            val entity = SessionEntity(
                id = id,
                vehicleId = "test-vehicle",
                kind = "PARKED",
                status = status,
                startedAtUtcMillis = startedAt.receivedAtUtcMillis,
                startedAtElapsedNanos = startedAt.receivedAtElapsedNanos,
                endedAtUtcMillis = null,
                startSocPercent = startSoc,
                endSocPercent = null,
                lastSoc = startSoc,
                startAmbientTempC = startAmbientTempC,
                endAmbientTempC = null,
                parkingMode = parkingMode,
                sleepSeconds = null,
                sleepSocDeltaPercent = null,
                sleepEnergyWhEstimate = null,
                endReason = null,
                createdAtUtcMillis = startedAt.receivedAtUtcMillis,
                updatedAtUtcMillis = startedAt.receivedAtUtcMillis,
                updatedAtElapsedNanos = startedAt.receivedAtElapsedNanos
            )
            openSession = entity
            return id
        }

        override fun updateParkedSessionLastSoc(
            id: String,
            lastSoc: Float?,
            updatedAt: SignalTimestamp
        ) {
            updateLastSocCount++
            val current = openSession
            if (current != null && current.id == id) {
                openSession = current.copy(
                    lastSoc = lastSoc,
                    updatedAtUtcMillis = updatedAt.receivedAtUtcMillis,
                    updatedAtElapsedNanos = updatedAt.receivedAtElapsedNanos
                )
            }
        }

        override fun updateParkedSessionParkingMode(
            id: String,
            parkingMode: Int,
            updatedAt: SignalTimestamp
        ) {
            val current = openSession
            if (current != null && current.id == id) {
                openSession = current.copy(
                    parkingMode = parkingMode,
                    updatedAtUtcMillis = updatedAt.receivedAtUtcMillis,
                    updatedAtElapsedNanos = updatedAt.receivedAtElapsedNanos
                )
            }
        }

        override fun updateParkedSessionSleepEstimate(
            id: String,
            sleepSeconds: Long,
            sleepSocDeltaPercent: Float,
            sleepEnergyWhEstimate: Double
        ) {
            val current = openSession
            if (current != null && current.id == id) {
                openSession = current.copy(
                    sleepSeconds = sleepSeconds,
                    sleepSocDeltaPercent = sleepSocDeltaPercent,
                    sleepEnergyWhEstimate = sleepEnergyWhEstimate
                )
            }
        }

        override fun closeParkedSession(
            id: String?,
            endedAt: SignalTimestamp,
            endSoc: Float?,
            endAmbientTempC: Float?,
            parkingMode: Int?,
            reason: String,
            sleepSeconds: Long?,
            sleepSocDeltaPercent: Float?,
            sleepEnergyWhEstimate: Double?
        ) {
            closedCount++
            lastCloseReason = reason
            val current = openSession
            if (current != null && current.id == id) {
                openSession = current.copy(
                    endedAtUtcMillis = endedAt.receivedAtUtcMillis,
                    endSocPercent = endSoc,
                    endAmbientTempC = endAmbientTempC,
                    parkingMode = parkingMode,
                    endReason = reason,
                    status = "ENDED",
                    sleepSeconds = sleepSeconds ?: current.sleepSeconds,
                    sleepSocDeltaPercent = sleepSocDeltaPercent ?: current.sleepSocDeltaPercent,
                    sleepEnergyWhEstimate = sleepEnergyWhEstimate ?: current.sleepEnergyWhEstimate,
                    updatedAtUtcMillis = endedAt.receivedAtUtcMillis,
                    updatedAtElapsedNanos = endedAt.receivedAtElapsedNanos
                )
            }
        }

        override fun deleteParkedSession(id: String) {
            if (openSession?.id == id) openSession = null
        }
    }

    private fun sample(seconds: Long, signalId: SignalKey, value: Any?): SignalSample {
        return SignalSample(
            signalId = signalId,
            value = value,
            unit = "",
            quality = SignalQuality.MEASURED,
            source = SignalSource.VHAL_POLLING,
            propertyId = 0,
            propertyIdHex = "0x00000000",
            areaId = 0,
            timestamp = SignalTimestamp(
                receivedAtUtcMillis = 1_700_000_000_000L + seconds * 1_000L,
                receivedAtElapsedNanos = (seconds + 1) * 1_000_000_000L,
                sourceTimestampNanos = null,
                accuracy = TimestampAccuracy.POLLED,
                uncertaintyMillis = 0L
            ),
            details = "test"
        )
    }

    private fun snapshot(
        seconds: Long,
        gear: Int = GeelyProperties.GEAR_PARK,
        speed: Float = 0f,
        soc: Float = 80f
    ): Map<SignalKey, SignalSample> = mapOf(
        SignalKey.GEAR to sample(seconds, SignalKey.GEAR, gear),
        SignalKey.VEHICLE_SPEED to sample(seconds, SignalKey.VEHICLE_SPEED, speed),
        SignalKey.HV_BATTERY_SOC to sample(seconds, SignalKey.HV_BATTERY_SOC, soc)
    )

    @Test
    fun `gear P for 30 seconds opens a parked session`() {
        val store = FakeParkedSessionStore()
        val detector = ParkedSessionDetector(store)

        // At 0s, armed
        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0))
        assertEquals(0, store.createdCount)
        assertNull(detector.activeFrameSession())

        // At 29s, still armed
        detector.onSignalUpdated(sample(29, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(29))
        assertEquals(0, store.createdCount)

        // At 30s, session opens
        detector.onSignalUpdated(sample(30, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(30))
        assertEquals(1, store.createdCount)
        assertNotNull(detector.activeFrameSession())
        assertEquals("PARKED", detector.activeFrameSession()?.type)
    }

    @Test
    fun `leaving gear P closes parked session with GEAR_LEFT_P`() {
        val store = FakeParkedSessionStore()
        val detector = ParkedSessionDetector(store)

        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0))
        detector.onSignalUpdated(sample(30, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(30))
        assertEquals(1, store.createdCount)

        // Shift to Drive
        detector.onSignalUpdated(
            sample(31, SignalKey.GEAR, GeelyProperties.GEAR_DRIVE),
            snapshot(31, gear = GeelyProperties.GEAR_DRIVE)
        )
        assertEquals(1, store.closedCount)
        assertEquals("GEAR_LEFT_P", store.lastCloseReason)
        assertNull(detector.activeFrameSession())
    }

    @Test
    fun `charge active closes parked session with CHARGE_OPENED`() {
        val store = FakeParkedSessionStore()
        var chargeActive = false
        val detector = ParkedSessionDetector(store, chargeActiveProvider = { chargeActive })

        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0))
        detector.onSignalUpdated(sample(30, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(30))
        assertEquals(1, store.createdCount)

        // Charge session opens
        chargeActive = true
        detector.onSignalUpdated(sample(31, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(31))
        assertEquals(1, store.closedCount)
        assertEquals("CHARGE_OPENED", store.lastCloseReason)
        assertNull(detector.activeFrameSession())
    }

    @Test
    fun `updateParkedSessionLastSoc only writes when SOC actually changes`() {
        val store = FakeParkedSessionStore()
        val detector = ParkedSessionDetector(store)

        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0, soc = 80.0f))
        detector.onSignalUpdated(sample(30, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(30, soc = 80.0f))
        val initialUpdates = store.updateLastSocCount

        // Send 10 identical SOC samples while active
        for (sec in 31L..40L) {
            detector.onSignalUpdated(sample(sec, SignalKey.HV_BATTERY_SOC, 80.0f), snapshot(sec, soc = 80.0f))
        }
        // No extra Room writes for identical SOC
        assertEquals(initialUpdates, store.updateLastSocCount)

        // Change SOC to 79.5f
        detector.onSignalUpdated(sample(41, SignalKey.HV_BATTERY_SOC, 79.5f), snapshot(41, soc = 79.5f))
        assertEquals(initialUpdates + 1, store.updateLastSocCount)
    }

    @Test
    fun `GEAR error sample with null value preserves lastGear and completes arming at 30 seconds`() {
        val store = FakeParkedSessionStore()
        val detector = ParkedSessionDetector(store)

        // Start in P at t = 0s
        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0, gear = GeelyProperties.GEAR_PARK))
        assertNull(detector.activeFrameSession())

        // Inject an error sample (null value for GEAR) at t = 10s (reproducing VHAL poll failure)
        val nullGearSample = SignalSample(
            signalId = SignalKey.GEAR,
            value = null,
            unit = "",
            quality = SignalQuality.UNAVAILABLE,
            source = SignalSource.VHAL_POLLING,
            propertyId = GeelyProperties.GearLever.propertyId,
            propertyIdHex = "0x11400401",
            areaId = 0,
            timestamp = SignalTimestamp(
                receivedAtUtcMillis = 1_700_000_010_000L,
                receivedAtElapsedNanos = 11_000_000_000L,
                sourceTimestampNanos = null,
                accuracy = TimestampAccuracy.POLLED,
                uncertaintyMillis = 0L
            ),
            details = "VHAL status=3 unavailable"
        )
        val snapWithNullGear = snapshot(10).toMutableMap().apply {
            put(SignalKey.GEAR, nullGearSample)
        }
        detector.onSignalUpdated(nullGearSample, snapWithNullGear)

        // Advance to 31s with normal SOC sample (uses preserved lastGear = P)
        detector.onSignalUpdated(sample(31, SignalKey.HV_BATTERY_SOC, 80.0f), snapshot(31, gear = GeelyProperties.GEAR_PARK))

        assertNotNull(store.openSession)
        assertEquals("ACTIVE", store.openSession?.status)
    }

    @Test
    fun `parkingMode is recorded on initial session creation when mode is active during arming`() {
        val store = FakeParkedSessionStore()
        val detector = ParkedSessionDetector(store)

        // Arm at t = 0 with PARKING_NAP_SWT = 1 and valid sourceTimestampNanos
        val napSample = SignalSample(
            signalId = SignalKey.PARKING_NAP_SWT,
            value = 1,
            unit = "",
            quality = SignalQuality.MEASURED,
            source = SignalSource.VHAL_POLLING,
            propertyId = GeelyProperties.ParkingNapSwt.propertyId,
            propertyIdHex = "0x2140A6D0",
            areaId = 0,
            timestamp = SignalTimestamp(
                receivedAtUtcMillis = 1_700_000_000_000L,
                receivedAtElapsedNanos = 100_000_000_000L,
                sourceTimestampNanos = 100_000_000_000L, // valid timestamp > 0
                accuracy = TimestampAccuracy.POLLED,
                uncertaintyMillis = 0
            ),
            details = ""
        )
        val snap = snapshot(0, gear = GeelyProperties.GEAR_PARK).toMutableMap().apply {
            put(SignalKey.PARKING_NAP_SWT, napSample)
        }

        detector.onSignalUpdated(napSample, snap)

        // Complete arming at t = 31s
        val snap31 = snapshot(31, gear = GeelyProperties.GEAR_PARK).toMutableMap().apply {
            put(SignalKey.PARKING_NAP_SWT, napSample)
        }
        detector.onSignalUpdated(sample(31, SignalKey.HV_BATTERY_SOC, 80.0f), snap31)

        assertNotNull(store.openSession)
        assertEquals(ParkedSessionDetector.PARKING_MODE_NAP, store.openSession?.parkingMode)
    }

    @Test
    fun `PARKING_NAP_SWT with sourceTimestampNanos 0 is ignored for mode detection`() {
        val store = FakeParkedSessionStore()
        val detector = ParkedSessionDetector(store)

        // Sample with sourceTimestampNanos = 0 (unverified default)
        val defaultNapSample = SignalSample(
            signalId = SignalKey.PARKING_NAP_SWT,
            value = 1,
            unit = "",
            quality = SignalQuality.MEASURED,
            source = SignalSource.VHAL_POLLING,
            propertyId = GeelyProperties.ParkingNapSwt.propertyId,
            propertyIdHex = "0x2140A6D0",
            areaId = 0,
            timestamp = SignalTimestamp(
                receivedAtUtcMillis = 1_700_000_000_000L,
                receivedAtElapsedNanos = 100_000_000_000L,
                sourceTimestampNanos = 0L, // unverified timestamp 0
                accuracy = TimestampAccuracy.POLLED,
                uncertaintyMillis = 0
            ),
            details = ""
        )
        val snap = snapshot(0, gear = GeelyProperties.GEAR_PARK).toMutableMap().apply {
            put(SignalKey.PARKING_NAP_SWT, defaultNapSample)
        }

        detector.onSignalUpdated(defaultNapSample, snap)
        detector.onSignalUpdated(sample(31, SignalKey.HV_BATTERY_SOC, 80.0f), snap)

        assertNotNull(store.openSession)
        assertNull(store.openSession?.parkingMode)
    }

    @Test
    fun `sleep gap estimate passes when elapsed and wall clock match without reboot (gate 4)`() {
        val store = FakeParkedSessionStore()
        val capacityWh = 39_400.0
        val detector = ParkedSessionDetector(store, capacityWhProvider = { capacityWh })

        val baseMs = 1_700_000_000_000L
        val baseNanos = 100_000_000_000L
        val estimate = detector.computeSleepGapEstimate(
            lastUtcMillis = baseMs,
            lastElapsedNanos = baseNanos,
            lastSoc = 80.0f,
            nowUtcMillis = baseMs + 2 * 3600 * 1000L, // 2 hours later
            nowElapsedNanos = baseNanos + 2 * 3600 * 1_000_000_000L, // exactly 2 hours later
            nowSoc = 79.0f, // 1.0% drop
            capacityWh = capacityWh
        )

        assertNotNull(estimate)
        assertEquals(7200L, estimate?.sleepSeconds)
        assertEquals(1.0f, estimate?.sleepSocDeltaPercent ?: 0f, 1e-4f)
        assertEquals(394.0, estimate?.sleepEnergyWhEstimate ?: 0.0, 1e-2)
    }

    @Test
    fun `sleep gap estimate rejects clock drift over 60 seconds without reboot (gate 4)`() {
        val store = FakeParkedSessionStore()
        val capacityWh = 39_400.0
        val detector = ParkedSessionDetector(store, capacityWhProvider = { capacityWh })

        val baseMs = 1_700_000_000_000L
        val baseNanos = 100_000_000_000L
        // Wall clock moved 2 hours, but elapsed realtime moved 1 hour (NTP or clock shift)
        val estimate = detector.computeSleepGapEstimate(
            lastUtcMillis = baseMs,
            lastElapsedNanos = baseNanos,
            lastSoc = 80.0f,
            nowUtcMillis = baseMs + 2 * 3600 * 1000L,
            nowElapsedNanos = baseNanos + 1 * 3600 * 1_000_000_000L,
            nowSoc = 79.0f,
            capacityWh = capacityWh
        )

        assertNull(estimate)
    }

    @Test
    fun `sleep gap estimate passes all 5 gates including system reboot`() {
        val store = FakeParkedSessionStore()
        val capacityWh = 39_400.0
        val detector = ParkedSessionDetector(store, capacityWhProvider = { capacityWh })

        val baseMs = 1_700_000_000_000L
        // System reboot: nowElapsedNanos (5_000_000_000L) < lastElapsedNanos (100_000_000_000L)
        val estimate = detector.computeSleepGapEstimate(
            lastUtcMillis = baseMs,
            lastElapsedNanos = 100_000_000_000L,
            lastSoc = 80.0f,
            nowUtcMillis = baseMs + 2 * 3600 * 1000L, // 2 hours later
            nowElapsedNanos = 5_000_000_000L,
            nowSoc = 79.0f, // 1.0% drop
            capacityWh = capacityWh
        )

        assertNotNull(estimate)
        assertEquals(7200L, estimate?.sleepSeconds)
        assertEquals(1.0f, estimate?.sleepSocDeltaPercent ?: 0f, 1e-4f)
        assertEquals(394.0, estimate?.sleepEnergyWhEstimate ?: 0.0, 1e-2)
    }

    @Test
    fun `sleep gap estimate rejects gap under 30 minutes (gate 1)`() {
        val store = FakeParkedSessionStore()
        val detector = ParkedSessionDetector(store, capacityWhProvider = { 39_400.0 })

        val baseMs = 1_700_000_000_000L
        val estimate = detector.computeSleepGapEstimate(
            lastUtcMillis = baseMs,
            lastElapsedNanos = 100_000_000_000L,
            lastSoc = 80.0f,
            nowUtcMillis = baseMs + 15 * 60 * 1000L, // 15 minutes
            nowElapsedNanos = 100_000_000_000L + 15 * 60 * 1_000_000_000L,
            nowSoc = 79.0f,
            capacityWh = 39_400.0
        )

        assertNull(estimate)
    }

    @Test
    fun `sleep gap estimate rejects SOC delta under 0 2 percent (gate 2)`() {
        val store = FakeParkedSessionStore()
        val detector = ParkedSessionDetector(store, capacityWhProvider = { 39_400.0 })

        val baseMs = 1_700_000_000_000L
        val estimate = detector.computeSleepGapEstimate(
            lastUtcMillis = baseMs,
            lastElapsedNanos = 100_000_000_000L,
            lastSoc = 80.0f,
            nowUtcMillis = baseMs + 2 * 3600 * 1000L,
            nowElapsedNanos = 100_000_000_000L + 2 * 3600 * 1_000_000_000L,
            nowSoc = 79.9f, // 0.1% drop
            capacityWh = 39_400.0
        )

        assertNull(estimate)
    }

    @Test
    fun `sleep gap estimate rejects a capacity no traction battery has (gate 3)`() {
        val store = FakeParkedSessionStore()
        val detector = ParkedSessionDetector(store, capacityWhProvider = { 150_000.0 })

        val baseMs = 1_700_000_000_000L
        val estimate = detector.computeSleepGapEstimate(
            lastUtcMillis = baseMs,
            lastElapsedNanos = 100_000_000_000L,
            lastSoc = 80.0f,
            nowUtcMillis = baseMs + 2 * 3600 * 1000L,
            nowElapsedNanos = 100_000_000_000L + 2 * 3600 * 1_000_000_000L,
            nowSoc = 79.0f,
            capacityWh = 300_000.0
        )

        assertNull(estimate)
    }

    @Test
    fun `sleep gap estimate rejects gap equal or over 24 hours (gate 5)`() {
        val store = FakeParkedSessionStore()
        val detector = ParkedSessionDetector(store, capacityWhProvider = { 39_400.0 })

        val baseMs = 1_700_000_000_000L
        val estimate = detector.computeSleepGapEstimate(
            lastUtcMillis = baseMs,
            lastElapsedNanos = 100_000_000_000L,
            lastSoc = 80.0f,
            nowUtcMillis = baseMs + 24 * 3600 * 1000L, // 24 hours
            nowElapsedNanos = 100_000_000_000L + 24 * 3600 * 1_000_000_000L,
            nowSoc = 75.0f,
            capacityWh = 39_400.0
        )

        assertNull(estimate)
    }

    @Test
    fun `camping mode says somebody is resting in the car`() {
        // The charging auto-open asks this before it takes the display.
        val snap = snapshot(0).toMutableMap().apply {
            put(
                SignalKey.PARKING_COMFORT_SWT,
                sample(0, SignalKey.PARKING_COMFORT_SWT, 1)
            )
        }

        assertTrue(ParkedSessionDetector.someoneIsRestingInside(snap))
    }

    @Test
    fun `parking climate alone is not somebody resting`() {
        // It is also how the car is warmed before a departure, with nobody in
        // it, and that runs on the cable — the arrival the screen opens for.
        val snap = snapshot(0).toMutableMap().apply {
            put(
                SignalKey.AC_PARKINGCLIMATESET,
                sample(0, SignalKey.AC_PARKINGCLIMATESET, 1)
            )
        }

        assertEquals(
            ParkedSessionDetector.PARKING_MODE_CLIMATE,
            ParkedSessionDetector.resolveParkingMode(snap)
        )
        assertFalse(ParkedSessionDetector.someoneIsRestingInside(snap))
    }

    @Test
    fun `a standing car with no mode is not somebody resting`() {
        assertFalse(ParkedSessionDetector.someoneIsRestingInside(snapshot(0)))
    }
}
