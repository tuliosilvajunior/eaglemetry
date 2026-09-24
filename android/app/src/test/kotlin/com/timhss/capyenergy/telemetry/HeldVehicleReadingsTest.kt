package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * What the energy accumulator is given, across a sequence of snapshot ticks.
 *
 * `FrameRepository` opens the Room database in its constructor, so it cannot be
 * built on the JVM. The thing worth pinning was never the repository, it was
 * what it hands on: [HeldVehicleReadings] decides which readings a frame
 * carries, and [composeCanStreamSample] builds the frame the accumulator gets.
 * Driving those two is driving the seam. Issue 188, first criterion.
 */
class HeldVehicleReadingsTest {

    private val second = 1_000_000_000L

    private fun sample(key: SignalKey, value: Double?, elapsedNanos: Long) = SignalSample(
        signalId = key,
        value = value,
        unit = key.unit,
        quality = SignalQuality.MEASURED,
        source = SignalSource.VHAL_POLLING,
        propertyId = 0,
        propertyIdHex = "0x00000000",
        areaId = 0,
        timestamp = SignalTimestamp(
            receivedAtUtcMillis = elapsedNanos / 1_000_000,
            receivedAtElapsedNanos = elapsedNanos,
            sourceTimestampNanos = null,
            accuracy = TimestampAccuracy.SOURCE_EVENT,
            uncertaintyMillis = 0L
        ),
        details = ""
    )

    private fun snapshot(
        odometerKm: Double?,
        socPercent: Double?,
        elapsedNanos: Long
    ): Map<SignalKey, SignalSample> = buildMap {
        odometerKm?.let { put(SignalKey.ODOMETER, sample(SignalKey.ODOMETER, it, elapsedNanos)) }
        socPercent?.let {
            put(SignalKey.HV_BATTERY_SOC, sample(SignalKey.HV_BATTERY_SOC, it, elapsedNanos))
        }
    }

    private fun metrics(elapsedNanos: Long) = RoadcastTripMetrics(
        drivePowerKw = 30.0f,
        packVoltageV = 380.0f,
        packCurrentA = -80.0f,
        packCurrentRaw = null,
        packCurrentEstimated = null,
        vehicleSpeedKmh = null,
        receivedAtElapsedNanos = elapsedNanos,
        sourceAgeNanos = 0L,
    )

    private fun frameAt(held: HeldVehicleReadings, elapsedNanos: Long) =
        composeCanStreamSample(
            metrics = metrics(elapsedNanos),
            speed = null,
            held = held,
            nowUtcMillis = elapsedNanos / 1_000_000
        )

    /**
     * The defect this ticket exists for.
     *
     * The car reports a moving odometer on every tick. Before the fix only a
     * reading that earned a `Sample` row reached the accumulator, and the
     * declared band is 0.1 km — on the 2026-08-26 snapshot the gap between two
     * written odometer rows on a trip runs to a median of 13 s and a 95th
     * percentile of 46 s. This walks thirty of those seconds.
     */
    @Test
    fun `the odometer the car reports reaches the frame on every tick`() {
        val held = HeldVehicleReadings()
        val odometers = mutableListOf<Float?>()

        for (tick in 0 until 30) {
            val now = (tick + 1) * second
            // 100 km/h: 27.8 m a second, so the odometer moves every tick and
            // crosses the 0.1 km band only every fourth one.
            held.observe(snapshot(3_000.0 + tick * 0.0278, 60.0, now), now)
            odometers.add(frameAt(held, now).odometerKm)
        }

        assertEquals(30, odometers.size)
        assertNull("no tick may be handed a missing odometer", odometers.firstOrNull { it == null })
        // Strictly rising: the accumulator sees the vehicle move on every tick,
        // not in 0.1 km lumps aligned to when the deadband agreed.
        for (i in 1 until odometers.size) {
            org.junit.Assert.assertTrue(
                "tick $i must report further than tick ${i - 1}",
                odometers[i]!! > odometers[i - 1]!!
            )
        }
        assertEquals(3_000.0f + 29 * 0.0278f, odometers.last()!!, 1e-3f)
    }

    /**
     * The old shape, stated as the thing that must not come back.
     *
     * A run of ticks where no reading is taken freezes the value the frame
     * carries, so a bucket built over those ticks records no distance at all
     * and the next reading's whole step lands in one bucket.
     */
    @Test
    fun `a run of ticks with no reading freezes what the frame carries`() {
        val held = HeldVehicleReadings()
        held.observe(snapshot(3_000.0, 60.0, second), second)

        val frozen = (2..20).map { frameAt(held, it * second).odometerKm }

        assertEquals(setOf(3_000.0f), frozen.toSet())
    }

    @Test
    fun `a held odometer expires the same way the charge does`() {
        val held = HeldVehicleReadings()
        held.observe(snapshot(3_000.0, 60.0, second), second)

        val withinBucket = second + HeldVehicleReadings.MAX_AGE_NANOS
        assertEquals(3_000.0f, frameAt(held, withinBucket).odometerKm)
        assertEquals(60.0f, frameAt(held, withinBucket).socPercent)

        val pastBucket = withinBucket + 1
        // Not a zero and not the last value: a reading measured in a different
        // bucket belongs to that one, and a bucket with no reading says so.
        assertNull(frameAt(held, pastBucket).odometerKm)
        assertNull(frameAt(held, pastBucket).socPercent)
    }

    @Test
    fun `a tick that reports nothing leaves the reading standing`() {
        // One unreadable tick is not a statement that the vehicle stopped
        // reporting. The value stands until it expires on its own.
        val held = HeldVehicleReadings()
        held.observe(snapshot(3_000.0, 60.0, second), second)
        held.observe(snapshot(null, null, 2 * second), 2 * second)

        assertEquals(3_000.0f, frameAt(held, 2 * second).odometerKm)
        assertEquals(60.0f, frameAt(held, 2 * second).socPercent)
    }

    @Test
    fun `a reading with no numeric value is not taken`() {
        val held = HeldVehicleReadings()
        held.observe(snapshot(3_000.0, 60.0, second), second)
        held.observe(snapshot(null, null, 2 * second), 2 * second)
        held.observeOne(SignalKey.ODOMETER, null, 2 * second)

        assertEquals(3_000.0f, frameAt(held, 2 * second).odometerKm)
    }

    @Test
    fun `the per-signal path takes the reading the deadband would have dropped`() {
        // `onSignalUpdated` used to capture inside the branch the deadband had
        // already decided to write. This is that path, and it must take the
        // value whatever the deadband thinks of it.
        val held = HeldVehicleReadings()
        held.observeOne(SignalKey.ODOMETER, 3_000.05, second)
        held.observeOne(SignalKey.HV_BATTERY_SOC, 59.9, second)

        assertEquals(3_000.05f, frameAt(held, second).odometerKm)
        assertEquals(59.9f, frameAt(held, second).socPercent)
    }

    @Test
    fun `a signal the readings do not hold is ignored`() {
        val held = HeldVehicleReadings()
        held.observeOne(SignalKey.VEHICLE_SPEED, 88.0, second)

        assertNull(frameAt(held, second).odometerKm)
        assertNull(frameAt(held, second).socPercent)
    }

    @Test
    fun `a reset drops both readings`() {
        val held = HeldVehicleReadings()
        held.observe(snapshot(3_000.0, 60.0, second), second)

        held.reset()

        assertNull(frameAt(held, second).odometerKm)
        assertNull(frameAt(held, second).socPercent)
    }

    @Test
    fun `a clock that has not started yields no reading`() {
        val held = HeldVehicleReadings()
        held.observe(snapshot(3_000.0, 60.0, 0L), 0L)

        assertNull(frameAt(held, second).odometerKm)
        assertNull(frameAt(held, 0L).odometerKm)
    }

    @Test
    fun `a frame carries the rest of the metrics untouched`() {
        val held = HeldVehicleReadings()
        held.observe(snapshot(3_000.0, 60.0, second), second)

        val speed = VhalSpeedReading(
            speedKmh = 88.0f,
            elapsedRealtimeNanos = second,
            wallTimeUtcMillis = 1_000L
        )
        val frame = composeCanStreamSample(metrics(second), speed, held, 1_234L)

        assertEquals(second, frame.elapsedRealtimeNanos)
        assertEquals(1_234L, frame.wallTimeUtcMillis)
        assertEquals(30.0f, frame.canDrivePowerKw)
        assertEquals(380.0f, frame.canPackVoltageV)
        assertEquals(-80.0f, frame.canPackCurrentA)
        assertEquals(88.0f, frame.speedKmh)
        assertEquals(second, frame.speedElapsedRealtimeNanos)
        assertEquals(1_000L, frame.speedWallTimeUtcMillis)
    }

    // ---------------------------------------------------------------------
    // What the buckets record, which is the point of all of the above.

    /**
     * Two minutes of steady 100 km/h, driven twice: once with the odometer
     * taken on every tick, once with it taken only when the 0.1 km band was
     * crossed. Both feed the same accumulator.
     *
     * The total is the same either way — the band loses nothing, it only
     * decides when the step is reported. What differs is which minute the
     * distance lands in, and that is the number the efficiency card divides by.
     */
    @Test
    fun `a bucket records the distance the vehicle drove, not the distance the deadband reported`() {
        val kmPerTick = 100.0 / 3_600.0
        val ticks = 0..120

        val everyTick = EnergyBucketAccumulator()
        val onWrittenRows = EnergyBucketAccumulator()
        val held = HeldVehicleReadings()
        val deadbanded = HeldVehicleReadings()
        var lastWritten = 3_000.0

        for (tick in ticks) {
            val now = (tick + 1) * second
            val odometer = 3_000.0 + tick * kmPerTick

            held.observe(snapshot(odometer, 60.0, now), now)
            everyTick.add(frameAt(held, now))

            // The old rule: the reading reaches the accumulator only when it
            // has already earned a Sample row.
            if (odometer - lastWritten >= 0.1 - 1e-9 || tick == 0) {
                lastWritten = odometer
                deadbanded.observe(snapshot(odometer, 60.0, now), now)
            }
            onWrittenRows.add(frameAt(deadbanded, now))
        }

        val fresh = everyTick.result().map { it.odometerDistanceKm }
        val stale = onWrittenRows.result().map { it.odometerDistanceKm }

        // Same drive, same total.
        assertEquals(fresh.sum(), stale.sum(), 0.11)

        // Every minute of a constant-speed drive covers the same ground.
        val minutes = fresh.dropLast(1)
        org.junit.Assert.assertTrue("expected whole minutes to compare", minutes.size >= 2)
        for (km in minutes) {
            // One tick short of the full minute: the first reading closes no
            // interval until the second one arrives, so a 60-tick minute
            // integrates 59 steps. 0.04 km covers that and the Float the
            // odometer is carried in.
            assertEquals("a full minute at 100 km/h is 1.667 km", 100.0 / 60.0, km, 0.04)
        }

        // The deadbanded run does not: its minutes are the 0.1 km steps that
        // happened to fall inside them.
        val spread = { xs: List<Double> -> (xs.maxOrNull() ?: 0.0) - (xs.minOrNull() ?: 0.0) }
        org.junit.Assert.assertTrue(
            "the deadbanded run must scatter across minutes more than the fresh one",
            spread(stale.dropLast(1)) > spread(minutes)
        )
    }

    /**
     * A minute the deadband never wrote in records no distance at all.
     *
     * On the 2026-08-26 snapshot, 23 of 550 recorded trip minutes moved more
     * than 50 m and hold no odometer row. Those are minutes whose
     * `odometerDistanceKm` is zero however far the vehicle went.
     */
    @Test
    fun `a minute with no written row records no odometer distance at all`() {
        val kmPerTick = 30.0 / 3_600.0
        val everyTick = EnergyBucketAccumulator()
        val frozen = EnergyBucketAccumulator()
        val held = HeldVehicleReadings()
        val stuck = HeldVehicleReadings()

        // 30 km/h for two minutes: 0.5 km, so the 0.1 km band is crossed, but
        // the first minute after a write goes by without another one.
        stuck.observe(snapshot(3_000.0, 60.0, second), second)
        for (tick in 0 until 120) {
            val now = (tick + 1) * second
            held.observe(snapshot(3_000.0 + tick * kmPerTick, 60.0, now), now)
            everyTick.add(frameAt(held, now))
            // The reading never moves: this is the minute with no row in it.
            stuck.observe(snapshot(3_000.0, 60.0, now), now)
            frozen.add(frameAt(stuck, now))
        }

        assertEquals(0.0, frozen.result().sumOf { it.odometerDistanceKm }, 1e-9)
        assertEquals(1.0, everyTick.result().sumOf { it.odometerDistanceKm }, 0.02)
    }

    /**
     * An expired odometer stops the integral rather than inventing a jump.
     *
     * The reading expires after one bucket. When it comes back the accumulator
     * must not read the whole silence as distance covered in one instant.
     */
    @Test
    fun `a reading that expired does not come back as a jump`() {
        val accumulator = EnergyBucketAccumulator()
        val held = HeldVehicleReadings()

        held.observe(snapshot(3_000.0, 60.0, second), second)
        accumulator.add(frameAt(held, second))

        // Nothing for five minutes, then the vehicle reappears 20 km further on.
        val later = second + 5 * 60 * second
        held.observe(snapshot(3_020.0, 55.0, later), later)
        accumulator.add(frameAt(held, later))

        val total = accumulator.result().sumOf { it.odometerDistanceKm }
        assertEquals("a gap is not distance", 0.0, total, 1e-9)
    }
}
