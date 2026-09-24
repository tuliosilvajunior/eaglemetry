package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import com.timhss.capyenergy.telemetry.db.SessionEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionTimelineTest {

    @Test
    fun `a session inside one boot needs no repair`() {
        assertFalse(SessionTimeline.spansReboot(trip(started = 7, movement = 7, ended = 7)))
        assertFalse(SessionTimeline.spansReboot(charge(connected = 7, disconnected = 7)))
    }

    @Test
    fun `a closed session with differing counters spans a reboot`() {
        assertTrue(SessionTimeline.spansReboot(trip(started = 7, movement = 7, ended = 8)))
        assertTrue(SessionTimeline.spansReboot(charge(connected = 7, disconnected = 8)))
    }

    @Test
    fun `an open session is compared against the boot we are in now`() {
        val open = charge(connected = 7, disconnected = null)
        assertFalse(SessionTimeline.spansReboot(open, currentBootCount = 7))
        assertTrue(SessionTimeline.spansReboot(open, currentBootCount = 8))
    }

    @Test
    fun `a closed session ignores the current boot`() {
        val closed = trip(started = 7, movement = 7, ended = 7)
        assertFalse(SessionTimeline.spansReboot(closed, currentBootCount = 12))
    }

    @Test
    fun `absent counters make no claim`() {
        assertFalse(SessionTimeline.spansReboot(trip(started = null, movement = null, ended = null)))
        assertFalse(
            SessionTimeline.spansReboot(
                trip(started = null, movement = null, ended = null),
                currentBootCount = 9
            )
        )
    }

    @Test
    fun `rebasing is monotonic and never lands on zero`() {
        val base = 1_000_000L
        assertEquals(1L, SessionTimeline.rebasedElapsedNanos(base, base))
        assertEquals(1_000_000_001L, SessionTimeline.rebasedElapsedNanos(base + 1_000, base))
        assertEquals(1L, SessionTimeline.rebasedElapsedNanos(base - 5_000, base))
    }

    @Test
    fun `rebasing recovers a charge integral that the elapsed clock destroys`() {
        val baseWallMillis = 1_700_000_000_000L
        val rows = (0 until 40).map { minute ->
            val rebooted = minute >= 20
            SessionAggregateSampleRow(
                id = minute.toLong() + 1,
                elapsedRealtimeNanos = if (rebooted) {
                    (minute - 20 + 1) * 60_000_000_000L
                } else {
                    (minute + 500) * 60_000_000_000L
                },
                wallTimeUtcMillis = baseWallMillis + minute * 60_000L,
                speedKmh = null,
                socPercent = null,
                odometerKm = null,
                voltageV = 400f,
                currentA = -17.5f,
                powerKw = null,
                freshnessMask = TelemetryEnergy.FRESH_VOLTAGE_MASK or
                    TelemetryEnergy.FRESH_CURRENT_MASK
            )
        }

        val rawOrder = SessionAggregateAccumulator().also { accumulator ->
            rows.sortedWith(compareBy({ it.elapsedRealtimeNanos }, { it.id }))
                .forEach(accumulator::add)
        }.durableChargeEnergyKwh()

        val rebased = SessionAggregateAccumulator().also { accumulator ->
            rows.sortedBy { it.id }.forEach { row ->
                accumulator.add(
                    row.copy(
                        elapsedRealtimeNanos = SessionTimeline.rebasedElapsedNanos(
                            row.wallTimeUtcMillis,
                            baseWallMillis
                        )
                    )
                )
            }
        }.durableChargeEnergyKwh()

        val expected = 7.0 * 39.0 / 60.0
        assertEquals(expected, rebased!!, 1e-9)
        assertTrue(
            "the elapsed clock must lose energy here, or this test proves nothing",
            rawOrder!! < expected - 0.01
        )
    }

    private fun trip(started: Int?, movement: Int?, ended: Int?) = SessionEntity(
        id = "trip",
        vehicleId = "test-vehicle",
        kind = "TRIP",
        status = if (ended == null) "ACTIVE" else "ENDED",
        startedAtUtcMillis = 1_000L,
        startedAtElapsedNanos = 1L,
        startedAtBootCount = started,
        movementStartedAtUtcMillis = null,
        movementStartedAtElapsedNanos = null,
        movementStartedAtBootCount = movement,
        endedAtUtcMillis = if (ended == null) null else 2_000L,
        endedAtElapsedNanos = null,
        endedAtBootCount = ended,
        startSocPercent = null,
        endSocPercent = null,
        startOdometerKm = null,
        endOdometerKm = null,
        startGear = null,
        endReason = null,
        createdAtUtcMillis = 1_000L,
        updatedAtUtcMillis = 1_000L
    )

    private fun charge(connected: Int?, disconnected: Int?) = SessionEntity(
        id = "charge",
        vehicleId = "test-vehicle",
        kind = "CHARGE",
        status = if (disconnected == null) "CHARGING" else "ENDED",
        startedAtUtcMillis = 1_000L,
        startedAtElapsedNanos = 1L,
        startedAtBootCount = connected,
        endedAtUtcMillis = disconnected?.let { 2_000L },
        plugDisconnectedAtUtcMillis = disconnected?.let { 2_000L },
        plugDisconnectedAtElapsedNanos = null,
        plugDisconnectedAtBootCount = disconnected,
        startSocPercent = null,
        endSocPercent = null,
        startOdometerKm = null,
        endOdometerKm = null,
        plugType = null,
        startPowerKw = null,
        costPerKwh = null,
        paidAmount = null,
        costCurrency = null,
        startAmbientTempC = null,
        endAmbientTempC = null,
        startLatitude = null,
        startLongitude = null,
        startAltitudeM = null,
        startGpsAccuracyM = null,
        startLocationProvider = null,
        startLocationElapsedRealtimeNanos = null,
        chargeEndReason = null,
        endReason = null,
        createdAtUtcMillis = 1_000L,
        updatedAtUtcMillis = 1_000L
    )
}
