package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.CanStreamSample
import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveEnergyBucketMonitorTest {

    /** 2026-08-03T13:39:00Z, on a minute boundary. */
    private val baseWallMillis = 1_785_505_140_000L

    private fun frame(seconds: Long, driveKw: Float = 40f, packCurrentA: Float = 105f) =
        SessionAggregateSampleRow(
            elapsedRealtimeNanos = (seconds + 1) * 1_000_000_000L,
            wallTimeUtcMillis = baseWallMillis + seconds * 1_000L,
            speedKmh = null,
            socPercent = null,
            odometerKm = null,
            voltageV = null,
            currentA = null,
            powerKw = null,
            freshnessMask = 0,
            canDrivePowerKw = driveKw,
            canPackVoltageV = 400f,
            canPackCurrentA = packCurrentA
        )

    private fun feed(
        monitor: LiveEnergyBucketMonitor,
        seconds: LongRange,
        sessionId: String = "trip-1",
        sessionType: String = "TRIP"
    ) {
        seconds.forEach { monitor.onFrame(sessionId, sessionType, frame(it)) }
    }

    @Test
    fun `the open minute grows as frames arrive`() {
        val monitor = LiveEnergyBucketMonitor()
        feed(monitor, 0..20L)
        val first = monitor.snapshot()!!.buckets.last().integratedSeconds

        feed(monitor, 21..40L)
        val second = monitor.snapshot()!!.buckets.last().integratedSeconds

        assertTrue("the open bar must keep filling", second > first)
        assertEquals(40.0, second, 1e-6)
    }

    @Test
    fun `a closed minute stays available after the next one opens`() {
        // The caller has to be able to watch a minute roll over without going
        // back to the database for the value it just watched accumulate.
        val monitor = LiveEnergyBucketMonitor()
        feed(monitor, 0..90L)

        val buckets = monitor.snapshot()!!.buckets
        assertEquals(2, buckets.size)
        assertEquals(baseWallMillis, buckets[0].startUtcMillis)
        assertEquals(60.0, buckets[0].integratedSeconds, 1e-6)
        // The second minute is still open and therefore short.
        assertTrue(buckets[1].integratedSeconds < 60.0)
    }

    @Test
    fun `the live fold matches what the stored series will report`() {
        // The open bar and the persisted series must be the same integral, or
        // the chart would step the moment the two met.
        val frames = (0..150L).map { frame(it, driveKw = 30f + (it % 17)) }

        val monitor = LiveEnergyBucketMonitor(windowMinutes = 10)
        frames.forEach { monitor.onFrame("trip-1", "TRIP", it) }

        val stored = EnergyBucketAccumulator().also { accumulator ->
            frames.forEach(accumulator::add)
        }.result()

        val live = monitor.snapshot()!!.buckets
        assertEquals(stored.size, live.size)
        stored.zip(live).forEach { (a, b) ->
            assertEquals(a.startUtcMillis, b.startUtcMillis)
            assertEquals(a.tractionWh, b.tractionWh, 1e-9)
            assertEquals(a.auxiliaryWh, b.auxiliaryWh, 1e-9)
            assertEquals(a.regeneratedWh, b.regeneratedWh, 1e-9)
        }
    }

    @Test
    fun `only the most recent minutes are kept`() {
        val monitor = LiveEnergyBucketMonitor(windowMinutes = 3)
        feed(monitor, 0..600L)

        val buckets = monitor.snapshot()!!.buckets
        assertEquals(3, buckets.size)
        // The window is a tail, so it ends on the minute in progress.
        assertEquals(
            EnergyBucket.BUCKET_MILLIS,
            buckets[1].startUtcMillis - buckets[0].startUtcMillis
        )
        // Ten minutes of frames end exactly on the boundary, so the tenth
        // minute is the last one with anything in it. A sample landing on a
        // boundary must not open an empty bucket beyond it.
        assertEquals(
            baseWallMillis + 9 * EnergyBucket.BUCKET_MILLIS,
            buckets.last().startUtcMillis
        )
        assertTrue(buckets.all { it.integratedSeconds > 0.0 })
    }

    @Test
    fun `a new trip starts a new series instead of continuing the old one`() {
        val monitor = LiveEnergyBucketMonitor()
        feed(monitor, 0..90L, sessionId = "trip-1")

        monitor.onFrame("trip-2", "TRIP", frame(200))
        monitor.onFrame("trip-2", "TRIP", frame(201))

        val snapshot = monitor.snapshot()!!
        assertEquals("trip-2", snapshot.sessionId)
        assertEquals(1, snapshot.buckets.size)
        assertEquals(1.0, snapshot.buckets.single().integratedSeconds, 1e-6)
    }

    @Test
    fun `a charge session does not register as drive consumption`() {
        val monitor = LiveEnergyBucketMonitor()
        monitor.onFrame("charge-1", "CHARGE", frame(0))
        monitor.onFrame("charge-1", "CHARGE", frame(1))

        assertNull(monitor.snapshot())
    }

    @Test
    fun `frames outside a session clear the series`() {
        // Parking ends the trip. Leaving the last bar on screen as if it were
        // still filling would be the screen lying about the car's state.
        val monitor = LiveEnergyBucketMonitor()
        feed(monitor, 0..30L)
        assertTrue(monitor.snapshot()!!.buckets.isNotEmpty())

        monitor.onFrame(null, null, frame(31))
        assertNull(monitor.snapshot())
    }

    @Test
    fun `no trip reports nothing rather than an empty trip`() {
        assertNull(LiveEnergyBucketMonitor().snapshot())
    }

    @Test
    fun `the monitor reports when it began seeing the trip`() {
        // A monitor started mid-drive has partial early buckets; callers need
        // the start to know which of its minutes it saw whole.
        val monitor = LiveEnergyBucketMonitor()
        monitor.onFrame("trip-1", "TRIP", frame(40))
        monitor.onFrame("trip-1", "TRIP", frame(41))

        val snapshot = monitor.snapshot()!!
        assertEquals(baseWallMillis + 40_000L, snapshot.startedAtUtcMillis)
        // That first minute is short: the monitor only saw its tail.
        assertTrue(snapshot.buckets.single().integratedSeconds < 60.0)
    }

    @Test
    fun `reset drops the series`() {
        val monitor = LiveEnergyBucketMonitor()
        feed(monitor, 0..30L)
        monitor.reset()
        assertNull(monitor.snapshot())
    }

    @Test
    fun `parked monitor accepts PARKED session and allows null driveKw`() {
        val monitor = LiveEnergyBucketMonitor(
            targetSessionType = "PARKED",
            allowMissingDriveAsZero = true
        )
        val parkedFrame0 = CanStreamSample(
            elapsedRealtimeNanos = 1_000_000_000L,
            wallTimeUtcMillis = baseWallMillis,
            canDrivePowerKw = null,
            canPackVoltageV = 400f,
            canPackCurrentA = 1.5f,
            canClimatePowerKw = 0.5f
        )
        val parkedFrame1 = CanStreamSample(
            elapsedRealtimeNanos = 2_000_000_000L,
            wallTimeUtcMillis = baseWallMillis + 1_000L,
            canDrivePowerKw = null,
            canPackVoltageV = 400f,
            canPackCurrentA = 1.5f,
            canClimatePowerKw = 0.5f
        )
        monitor.onFrame("parked-1", "PARKED", parkedFrame0)
        monitor.onFrame("parked-1", "PARKED", parkedFrame1)

        val snapshot = monitor.snapshot()
        assertNotNull(snapshot)
        assertEquals("parked-1", snapshot?.sessionId)
        assertEquals(1, snapshot?.buckets?.size)
        val bucket = snapshot!!.buckets.single()
        assertEquals(1.0, bucket.integratedSeconds, 1e-6)
        assertTrue("auxiliaryWh must be integrated", bucket.auxiliaryWh > 0.0)
    }

    @Test
    fun `continuous monitor accumulates regardless of gear, speed or session state`() {
        // Built the way FrameRepository builds it: no gate, missing drive
        // power reads as zero rather than dropping the frame. Issue 199/205.
        val monitor = LiveEnergyBucketMonitor(
            targetSessionType = LiveEnergyBucketMonitor.CONTINUOUS_SESSION_TYPE,
            allowMissingDriveAsZero = true
        )
        val standingFrame0 = CanStreamSample(
            elapsedRealtimeNanos = 1_000_000_000L,
            wallTimeUtcMillis = baseWallMillis,
            canDrivePowerKw = null,
            canPackVoltageV = 400f,
            canPackCurrentA = 1.5f,
            canClimatePowerKw = 0.5f
        )
        val standingFrame1 = CanStreamSample(
            elapsedRealtimeNanos = 2_000_000_000L,
            wallTimeUtcMillis = baseWallMillis + 1_000L,
            canDrivePowerKw = null,
            canPackVoltageV = 400f,
            canPackCurrentA = 1.5f,
            canClimatePowerKw = 0.5f
        )
        monitor.onFrame("continuous-1", "CONTINUOUS", standingFrame0)
        monitor.onFrame("continuous-1", "CONTINUOUS", standingFrame1)

        val snapshot = monitor.snapshot()
        assertNotNull(snapshot)
        assertEquals("continuous-1", snapshot?.sessionId)
        val bucket = snapshot!!.buckets.single()
        assertEquals(1.0, bucket.integratedSeconds, 1e-6)
        assertTrue("auxiliaryWh must be integrated with no drive power", bucket.auxiliaryWh > 0.0)
    }

    @Test
    fun `a trip's minutes still land under the trip while continuous records the same frame`() {
        // Duplication is accepted by design: the continuous monitor and the
        // trip monitor are independent instances fed the same frame, and
        // neither one's boundaries depend on the other's.
        val tripMonitor = LiveEnergyBucketMonitor()
        val continuousMonitor = LiveEnergyBucketMonitor(
            targetSessionType = LiveEnergyBucketMonitor.CONTINUOUS_SESSION_TYPE,
            allowMissingDriveAsZero = true
        )

        (0..30L).forEach { seconds ->
            val driveFrame = frame(seconds)
            tripMonitor.onFrame("trip-1", "TRIP", driveFrame)
            continuousMonitor.onFrame("continuous-1", "CONTINUOUS", driveFrame)
        }

        val tripBucket = tripMonitor.snapshot()!!.buckets.single()
        val continuousBucket = continuousMonitor.snapshot()!!.buckets.single()
        assertEquals(tripBucket.tractionWh, continuousBucket.tractionWh, 1e-9)
        assertEquals(tripBucket.integratedSeconds, continuousBucket.integratedSeconds, 1e-6)
    }

    @Test
    fun `charge climate monitor accepts CHARGE session with climateOnly without drive power`() {
        val monitor = LiveEnergyBucketMonitor(
            targetSessionType = "CHARGE",
            climateOnly = true
        )
        val chargeFrame0 = CanStreamSample(
            elapsedRealtimeNanos = 1_000_000_000L,
            wallTimeUtcMillis = baseWallMillis,
            canDrivePowerKw = null,
            canPackVoltageV = null,
            canPackCurrentA = null,
            canClimatePowerKw = 1.2f
        )
        val chargeFrame1 = CanStreamSample(
            elapsedRealtimeNanos = 2_000_000_000L,
            wallTimeUtcMillis = baseWallMillis + 1_000L,
            canDrivePowerKw = null,
            canPackVoltageV = null,
            canPackCurrentA = null,
            canClimatePowerKw = 1.2f
        )
        monitor.onFrame("charge-1", "CHARGE", chargeFrame0)
        monitor.onFrame("charge-1", "CHARGE", chargeFrame1)

        val snapshot = monitor.snapshot()
        assertNotNull(snapshot)
        assertEquals("charge-1", snapshot?.sessionId)
        assertEquals(1, snapshot?.buckets?.size)
        val bucket = snapshot!!.buckets.single()
        assertEquals(0.0, bucket.integratedSeconds, 1e-6)
        assertEquals(1.0, bucket.climateIntegratedSeconds, 1e-6)
        assertTrue("climateWh must be integrated", bucket.climateWh > 0.0)
    }

    @Test
    fun `buckets older than the retain window cannot be resurrected`() {
        val monitor = LiveEnergyBucketMonitor(windowMinutes = 3)
        feed(monitor, 0..1200L)

        // Twenty minutes of frames. Asking past the retain window must not
        // bring back minutes the accumulator has already dropped.
        val buckets = monitor.snapshot(20)!!.buckets
        assertEquals(3, buckets.size)
        assertEquals(
            baseWallMillis + 17 * EnergyBucket.BUCKET_MILLIS,
            buckets.first().startUtcMillis
        )
    }

    /**
     * Finding 13c: pinned through [LiveEnergyBucketMonitors.charge] — the
     * same factory `FrameRepository` uses — not an inline constructor with
     * hand-picked flags.
     *
     * The 2026-08-20 defect was not in the fold but in this argument: the charge
     * monitor was `climateOnly`, so `deliveredWh` was never accumulated and every
     * recorded charge stored zero delivered energy. `IntervalFixtureTest` proved
     * the fold by constructing the accumulator itself with `deliveredOnly = true`,
     * which is exactly the step that hides a wrong flag here.
     */
    @Test
    fun `the charge monitor folds delivered energy, not only climate`() {
        val monitor = LiveEnergyBucketMonitors.charge(retainBuckets = 20)

        // 400 V at -18 A is a 7.2 kW charge: pack power is discharge-positive, so
        // a charging pack reads negative and `delivered` is its sign flip.
        (0..59L).forEach {
            monitor.onFrame("charge-1", "CHARGE", chargeFrame(it, packCurrentA = -18f))
        }

        val buckets = monitor.snapshot()!!.buckets
        val deliveredWh = buckets.sumOf { it.deliveredWh }
        val coveredSeconds = buckets.sumOf { it.deliveredCoveredSeconds }

        assertEquals("59 s at 7.2 kW", 7_200.0 * 59.0 / 3_600.0, deliveredWh, 1e-6)
        assertEquals(59.0, coveredSeconds, 1e-6)
        assertTrue("a charge must not report traction", buckets.all { it.tractionWh == 0.0 })
    }

    /**
     * `CONTINUOUS` (and `PARKED`) spans both driving and charging, unlike the
     * charge monitor above, so it cannot run `deliveredOnly` — it needs the
     * per-frame `isCharging` flag instead. Before issue 199/211's fix, a
     * charging minute fell through into `auxiliaryWh`, which went negative
     * (`packKw` with no drive power to subtract) and drew as a broken bar on
     * the "Since power on" chart while the real charge energy stayed invisible.
     */
    @Test
    fun `the continuous monitor folds delivered energy during a charge without touching auxiliary`() {
        // Finding 13c: same factory `FrameRepository` uses, so a wiring
        // regression fails here instead of hiding behind inline flags.
        val monitor = LiveEnergyBucketMonitors.continuous(retainBuckets = 20)

        // Same 400 V / -18 A / 7.2 kW charge as the dedicated charge monitor
        // above, but folded by the accumulator that also has to know how to
        // draw a trip minute — this is the seam the fix threads a flag through.
        (0..59L).forEach {
            monitor.onFrame(
                "continuous-1",
                LiveEnergyBucketMonitor.CONTINUOUS_SESSION_TYPE,
                frame(it, driveKw = 0f, packCurrentA = -18f),
                isCharging = true
            )
        }

        val buckets = monitor.snapshot()!!.buckets
        val deliveredWh = buckets.sumOf { it.deliveredWh }

        assertEquals("59 s at 7.2 kW", 7_200.0 * 59.0 / 3_600.0, deliveredWh, 1e-6)
        assertTrue(
            "charging must not report negative auxiliary",
            buckets.all { it.auxiliaryWh == 0.0 }
        )
        assertTrue("charging must not report traction", buckets.all { it.tractionWh == 0.0 })
    }

    @Test
    fun `the snapshot carries the first-sample pair through to the flush`() {
        // T2: the monitor and the flush pass the pair without altering it —
        // the bucket born in the accumulator is the pair the row stores. A
        // monitor that dropped it here would waste T1's columns.
        val monitor = LiveEnergyBucketMonitors.trip(
            retainBuckets = 20,
            bootCountProvider = { 41 }
        )
        feed(monitor, 0..90L)

        val buckets = monitor.snapshot()!!.buckets
        assertEquals(2, buckets.size)
        for (bucket in buckets) {
            assertEquals(41, bucket.startBootCount)
        }
        assertEquals(1_000_000_000L, buckets[0].startElapsedNanos)
        assertEquals(61_000_000_000L, buckets[1].startElapsedNanos)
        // Every flushed row is born with both columns filled, never null.
        val rows = buckets.map { it.toEntity("trip-1", updatedAtUtcMillis = 0L) }
        assertTrue(rows.all { it.startElapsedNanos != null && it.startBootCount != null })
    }

    /** A charge frame: no drive power on the bus, the pack taking current. */
    private fun chargeFrame(seconds: Long, packCurrentA: Float) = CanStreamSample(
        elapsedRealtimeNanos = (seconds + 1) * 1_000_000_000L,
        wallTimeUtcMillis = baseWallMillis + seconds * 1_000L,
        canDrivePowerKw = null,
        canPackVoltageV = 400f,
        canPackCurrentA = packCurrentA
    )
}
