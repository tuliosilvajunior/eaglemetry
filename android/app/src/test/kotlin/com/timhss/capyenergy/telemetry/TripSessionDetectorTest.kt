package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.profile.GeelyProperties
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TripSessionDetectorTest {
    @Test
    fun shortStreetToGarageManeuverDoesNotCreateTrip() {
        val events = FakeTripEventSink()
        val sessions = FakeTripSessionStore()
        val detector = TripSessionDetector(events, sessions)

        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0))
        detector.onSignalUpdated(sample(1, SignalKey.GEAR, GeelyProperties.GEAR_DRIVE), snapshot(1, gear = GeelyProperties.GEAR_DRIVE))

        for (second in 2..24 step 2) {
            detector.onSignalUpdated(
                sample(second, SignalKey.VEHICLE_SPEED, 5f),
                snapshot(second, gear = GeelyProperties.GEAR_DRIVE, speed = 5f)
            )
        }

        detector.onSignalUpdated(sample(30, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(30))

        assertEquals(0, sessions.createdTrips)
        assertTrue(events.events.any { it.type == TelemetryEventType.TRIP_CANCELLED })
    }

    @Test
    fun materialDriveCreatesTripAfterDistanceThreshold() {
        val events = FakeTripEventSink()
        val sessions = FakeTripSessionStore()
        val detector = TripSessionDetector(events, sessions)

        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0))
        detector.onSignalUpdated(sample(1, SignalKey.GEAR, GeelyProperties.GEAR_DRIVE), snapshot(1, gear = GeelyProperties.GEAR_DRIVE))

        for (second in 2..36 step 2) {
            detector.onSignalUpdated(
                sample(second, SignalKey.VEHICLE_SPEED, 30f),
                snapshot(second, gear = GeelyProperties.GEAR_DRIVE, speed = 30f)
            )
        }

        assertEquals(1, sessions.createdTrips)
        assertTrue(events.events.any { it.type == TelemetryEventType.TRIP_STARTED })
    }

    @Test
    fun parkReverseDriveDepartureCreatesTrip() {
        val events = FakeTripEventSink()
        val sessions = FakeTripSessionStore()
        val detector = TripSessionDetector(events, sessions)

        // Real-world departure: back out of the spot (Park -> Reverse), then Drive.
        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0))
        detector.onSignalUpdated(
            sample(1, SignalKey.GEAR, GeelyProperties.GEAR_REVERSE),
            snapshot(1, gear = GeelyProperties.GEAR_REVERSE)
        )
        detector.onSignalUpdated(
            sample(2, SignalKey.GEAR, GeelyProperties.GEAR_DRIVE),
            snapshot(2, gear = GeelyProperties.GEAR_DRIVE)
        )

        for (second in 3..37 step 2) {
            detector.onSignalUpdated(
                sample(second, SignalKey.VEHICLE_SPEED, 30f),
                snapshot(second, gear = GeelyProperties.GEAR_DRIVE, speed = 30f)
            )
        }

        assertEquals(1, sessions.createdTrips)
        assertTrue(events.events.any { it.type == TelemetryEventType.TRIP_ARMED })
        assertTrue(events.events.any { it.type == TelemetryEventType.TRIP_STARTED })
    }

    @Test
    fun tripEventsCarrySessionId() {
        val events = FakeTripEventSink()
        val sessions = FakeTripSessionStore()
        val detector = TripSessionDetector(events, sessions)

        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0))
        detector.onSignalUpdated(sample(1, SignalKey.GEAR, GeelyProperties.GEAR_DRIVE), snapshot(1, gear = GeelyProperties.GEAR_DRIVE))

        val armedEvent = events.events.first { it.type == TelemetryEventType.TRIP_ARMED }
        assertTrue(armedEvent.sessionId != null)
        val expectedSessionId = armedEvent.sessionId

        for (second in 2..36 step 2) {
            detector.onSignalUpdated(
                sample(second, SignalKey.VEHICLE_SPEED, 30f),
                snapshot(second, gear = GeelyProperties.GEAR_DRIVE, speed = 30f)
            )
        }

        val startedEvent = events.events.first { it.type == TelemetryEventType.TRIP_STARTED }
        assertEquals(expectedSessionId, startedEvent.sessionId)

        // Enter park -> pending end
        detector.onSignalUpdated(sample(40, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(40, speed = 0f))
        val pendingEndEvent = events.events.first { it.type == TelemetryEventType.TRIP_PENDING_END }
        assertEquals(expectedSessionId, pendingEndEvent.sessionId)

        // Confirm park -> trip ended (35s after entering park; threshold is 30s)
        detector.onSignalUpdated(sample(75, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(75, speed = 0f))
        val endedEvent = events.events.first { it.type == TelemetryEventType.TRIP_ENDED }
        assertEquals(expectedSessionId, endedEvent.sessionId)
    }

    /**
     * A trip records where it began.
     *
     * A charge has carried its start location since it was written; a trip
     * never did, so `session.startLatitude` was null on every recorded drive
     * up to 2026-08-20. The detector is the only object that knows when a trip
     * opens, so the fix belongs here rather than in a later back-stamp.
     */
    @Test
    fun armingATripRecordsWhereItBegan() {
        val events = FakeTripEventSink()
        val sessions = FakeTripSessionStore()
        val fix = LocationSnapshot(
            latitude = -23.5505,
            longitude = -46.6333,
            altitudeM = 760.0,
            accuracyM = 8f,
            provider = "gps",
            elapsedRealtimeNanos = 1_000_000_000L,
            wallTimeUtcMillis = 1_787_000_000_000L
        )
        val detector = TripSessionDetector(events, sessions) { fix }

        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0))
        detector.onSignalUpdated(
            sample(1, SignalKey.GEAR, GeelyProperties.GEAR_DRIVE),
            snapshot(1, gear = GeelyProperties.GEAR_DRIVE)
        )

        assertEquals(1, sessions.createdTrips)
        assertEquals(fix, sessions.lastStartLocation)
    }

    /** No fix is a trip with no start location, not a trip that is refused. */
    @Test
    fun aTripWithoutAFixStillOpens() {
        val events = FakeTripEventSink()
        val sessions = FakeTripSessionStore()
        val detector = TripSessionDetector(events, sessions) { null }

        detector.onSignalUpdated(sample(0, SignalKey.GEAR, GeelyProperties.GEAR_PARK), snapshot(0))
        detector.onSignalUpdated(
            sample(1, SignalKey.GEAR, GeelyProperties.GEAR_DRIVE),
            snapshot(1, gear = GeelyProperties.GEAR_DRIVE)
        )

        assertEquals(1, sessions.createdTrips)
        assertEquals(null, sessions.lastStartLocation)
    }

    private fun snapshot(
        seconds: Int,
        gear: Int = GeelyProperties.GEAR_PARK,
        speed: Float = 0f,
        odometer: Float = 100f,
        soc: Float = 50f
    ): Map<SignalKey, SignalSample> = mapOf(
        SignalKey.GEAR to sample(seconds, SignalKey.GEAR, gear),
        SignalKey.VEHICLE_SPEED to sample(seconds, SignalKey.VEHICLE_SPEED, speed),
        SignalKey.ODOMETER to sample(seconds, SignalKey.ODOMETER, odometer),
        SignalKey.HV_BATTERY_SOC to sample(seconds, SignalKey.HV_BATTERY_SOC, soc)
    )

    private fun sample(seconds: Int, signalId: SignalKey, value: Any?): SignalSample {
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
                receivedAtElapsedNanos = seconds * 1_000_000_000L,
                sourceTimestampNanos = null,
                accuracy = TimestampAccuracy.POLLED,
                uncertaintyMillis = 0L
            ),
            details = "test"
        )
    }
}

private class FakeTripEventSink : TripEventSink {
    val events = mutableListOf<TelemetryEvent>()

    override fun appendEvent(event: TelemetryEvent) {
        events.add(event)
    }

    override fun sessionEvent(
        type: TelemetryEventType,
        timestamp: SignalTimestamp,
        value: Any?,
        previousValue: Any?,
        source: SignalSource?,
        details: String,
        sessionId: String?
    ): TelemetryEvent {
        return TelemetryEvent(
            id = UUID.randomUUID().toString(),
            type = type,
            timestamp = timestamp,
            signalId = null,
            value = value,
            previousValue = previousValue,
            quality = null,
            source = source,
            details = details,
            sessionId = sessionId
        )
    }
}

private class FakeTripSessionStore : TripSessionStore {
    var createdTrips = 0
    var activeStatus: String? = null
    var wasMarkedActive = false

    /** What the detector said the trip began at. Null until one is created. */
    var lastStartLocation: LocationSnapshot? = null

    override fun latestOpenTripSession(): SessionEntity? = null

    override fun createTripSession(
        startedAt: SignalTimestamp,
        movementStartedAt: SignalTimestamp?,
        startSoc: Float?,
        startOdometerKm: Float?,
        startGear: Int?,
        startLocation: LocationSnapshot?,
        status: String
    ): String {
        createdTrips += 1
        activeStatus = status
        lastStartLocation = startLocation
        return UUID.randomUUID().toString()
    }

    override fun closeTripSession(
        id: String?,
        startedAt: SignalTimestamp?,
        movementStartedAt: SignalTimestamp?,
        endedAt: SignalTimestamp,
        startSoc: Float?,
        endSoc: Float?,
        startOdometerKm: Float?,
        endOdometerKm: Float?,
        startGear: Int?,
        reason: TripEndReason
    ) = Unit

    override fun markTripActive(id: String, movementStartedAt: SignalTimestamp) {
        wasMarkedActive = true
        activeStatus = "ACTIVE"
    }

    override fun deleteTripSession(id: String) {
        createdTrips = (createdTrips - 1).coerceAtLeast(0)
    }
}
