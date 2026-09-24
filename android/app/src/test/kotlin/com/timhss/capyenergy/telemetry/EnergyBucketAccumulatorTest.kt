package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.CanStreamSample
import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EnergyBucketAccumulatorTest {

    /** 2026-08-03T13:39:00Z, already on a minute boundary. */
    private val baseWallMillis = 1_785_505_140_000L

    private fun sample(
        seconds: Long,
        driveKw: Float,
        packVoltageV: Float = 400f,
        packCurrentA: Float,
        wallOffsetMillis: Long = seconds * 1_000L,
        speedKmh: Float? = null,
        odometerKm: Float? = null,
        socPercent: Float? = null
    ) = SessionAggregateSampleRow(
        // Offset by a second: an elapsed clock of zero is the "no usable
        // timestamp" sentinel the accumulator rejects, so a fixture starting
        // there would silently lose its first sample. Only deltas matter.
        elapsedRealtimeNanos = (seconds + 1) * 1_000_000_000L,
        wallTimeUtcMillis = baseWallMillis + wallOffsetMillis,
        speedKmh = speedKmh,
        socPercent = socPercent,
        odometerKm = odometerKm,
        voltageV = null,
        currentA = null,
        powerKw = null,
        freshnessMask = 0,
        canDrivePowerKw = driveKw,
        canPackVoltageV = packVoltageV,
        canPackCurrentA = packCurrentA
    )

    private fun accumulate(
        samples: List<SessionAggregateSampleRow>
    ): List<EnergyBucket> {
        val accumulator = EnergyBucketAccumulator()
        samples.forEach(accumulator::add)
        return accumulator.result()
    }

    @Test
    fun `buckets start on the wall-clock minute regardless of when the trip began`() {
        // A trip that starts at 13:39:20 still reports a bucket labelled 13:39,
        // so the axis reads in round minutes and adjacent buckets can be merged
        // onto the same boundaries a wider bar would use.
        val offset = 20_000L
        val buckets = accumulate(
            (0..30L).map { second ->
                sample(
                    seconds = second,
                    driveKw = 50f,
                    packCurrentA = 125f,
                    wallOffsetMillis = offset + second * 1_000L
                )
            }
        )

        assertEquals(1, buckets.size)
        assertEquals(baseWallMillis, buckets.single().startUtcMillis)
        assertEquals(0L, buckets.single().startUtcMillis % EnergyBucket.BUCKET_MILLIS)
    }

    @Test
    fun `an interval crossing a minute is split at the boundary`() {
        // Two samples 10 s apart straddling 13:40:00 with constant power: the
        // energy has to land 4 s in the first minute and 6 s in the second, not
        // 10 s in whichever end won.
        val buckets = accumulate(
            listOf(
                sample(
                    seconds = 0,
                    driveKw = 36f,
                    packCurrentA = 90f,
                    wallOffsetMillis = 56_000L
                ),
                sample(
                    seconds = 10,
                    driveKw = 36f,
                    packCurrentA = 90f,
                    wallOffsetMillis = 66_000L
                )
            )
        )

        assertEquals(2, buckets.size)
        assertEquals(4.0, buckets[0].integratedSeconds, 1e-6)
        assertEquals(6.0, buckets[1].integratedSeconds, 1e-6)

        // 36 kW for 4 s is 40 Wh; for 6 s, 60 Wh.
        assertEquals(40.0, buckets[0].tractionWh, 1e-6)
        assertEquals(60.0, buckets[1].tractionWh, 1e-6)
    }

    @Test
    fun `summed buckets equal the session integral`() {
        // The chart and the session summary must not be two estimates of the
        // same trip. Both fold the same samples, so their totals have to match
        // to the last decimal.
        val samples = (0..300L).map { second ->
            val phase = second.toDouble() / 30.0
            val driveKw = (40.0 * kotlin.math.sin(phase)).toFloat()
            sample(
                seconds = second,
                driveKw = driveKw,
                packCurrentA = (driveKw * 1000f / 400f) + 5f,
                packVoltageV = 400f
            )
        }

        val session = TripPowerAccumulator().also { accumulator ->
            samples.forEach(accumulator::add)
        }.result()!!

        val buckets = accumulate(samples)
        assertTrue("expected several minutes", buckets.size >= 5)

        assertEquals(session.tractionWh, buckets.sumOf { it.tractionWh }, 1e-6)
        assertEquals(session.regeneratedWh, buckets.sumOf { it.regeneratedWh }, 1e-6)
        assertEquals(session.auxiliaryWh, buckets.sumOf { it.auxiliaryWh }, 1e-6)
        assertEquals(
            session.integratedSeconds,
            buckets.sumOf { it.integratedSeconds },
            1e-6
        )
    }

    @Test
    fun `window metrics are split into the same minutes as power`() {
        val samples = (0..120L).map { second ->
            sample(
                seconds = second,
                driveKw = 36f,
                packCurrentA = 90f,
                speedKmh = 36f,
                odometerKm = (100.0 + second * 0.01).toFloat()
            )
        }

        val buckets = accumulate(samples)

        assertEquals(2, buckets.size)
        assertEquals(1.2, buckets.sumOf { it.speedDistanceKm }, 1e-6)
        assertEquals(1.2, buckets.sumOf { it.odometerDistanceKm }, 1e-4)
        assertEquals(120.0, buckets.sumOf { it.speedIntegratedSeconds }, 1e-6)
        val averageSpeed =
            buckets.sumOf { it.speedDistanceKm } * 3_600.0 /
                buckets.sumOf { it.speedIntegratedSeconds }
        assertEquals(36.0, averageSpeed, 1e-6)
    }

    @Test
    fun `merging adjacent buckets reproduces a wider bucket exactly`() {
        // This is what the chart does when a trip outgrows its bar budget, so
        // a five-minute bar must be the sum of its five minutes and nothing
        // else. Re-integration is never allowed to be the fallback.
        val samples = (0..600L).map { second ->
            val driveKw = (30.0 + 10.0 * kotlin.math.cos(second / 20.0)).toFloat()
            sample(
                seconds = second,
                driveKw = driveKw,
                packCurrentA = (driveKw * 1000f / 400f) + 3f
            )
        }

        val buckets = accumulate(samples)
        val firstFive = buckets.take(5)
        assertEquals(5, firstFive.size)

        // Contiguous and exactly one minute apart, which is what makes the sum
        // a valid five-minute bar rather than five unrelated readings.
        firstFive.zipWithNext { a, b ->
            assertEquals(EnergyBucket.BUCKET_MILLIS, b.startUtcMillis - a.startUtcMillis)
        }
        assertEquals(300.0, firstFive.sumOf { it.integratedSeconds }, 1e-6)
    }

    @Test
    fun `a gap in the data breaks the series instead of being integrated across`() {
        // Frames stop for two minutes. Those minutes carry no reading at all;
        // the accumulator must not draw a plateau across them.
        val samples = (0..10L).map { sample(it, 40f, packCurrentA = 100f) } +
            (190..200L).map {
                sample(it, 40f, packCurrentA = 100f)
            }

        val buckets = accumulate(samples)
        val covered = buckets.map { it.startUtcMillis }.toSet()

        assertEquals(
            setOf(baseWallMillis, baseWallMillis + 3 * EnergyBucket.BUCKET_MILLIS),
            covered
        )
        assertEquals(10.0, buckets.first().integratedSeconds, 1e-6)
        assertEquals(10.0, buckets.last().integratedSeconds, 1e-6)
    }

    @Test
    fun `regeneration lands in its own total, not as negative traction`() {
        val samples = (0..60L).map { second ->
            val driveKw = if (second < 30) 40f else -20f
            sample(second, driveKw, packCurrentA = (driveKw * 1000f / 400f))
        }

        val buckets = accumulate(samples)
        val traction = buckets.sumOf { it.tractionWh }
        val regenerated = buckets.sumOf { it.regeneratedWh }

        assertTrue("traction stays positive", traction > 0.0)
        assertTrue("regeneration stays positive", regenerated > 0.0)
        // Neither bucket may report a negative traction figure: the split is
        // into two non-negative series, which is what the chart draws above and
        // below its zero line.
        assertTrue(buckets.all { it.tractionWh >= 0.0 })
        assertTrue(buckets.all { it.regeneratedWh >= 0.0 })
    }

    @Test
    fun `a wall clock that jumps does not split the interval at a guess`() {
        // The wall clock steps forward a minute between two samples one second
        // apart. There is no real crossing point inside that interval, so the
        // energy belongs whole to the minute it started in.
        val buckets = accumulate(
            listOf(
                sample(seconds = 0, driveKw = 36f, packCurrentA = 90f, wallOffsetMillis = 0L),
                sample(
                    seconds = 1,
                    driveKw = 36f,
                    packCurrentA = 90f,
                    wallOffsetMillis = 61_000L
                )
            )
        )

        assertEquals(1, buckets.size)
        assertEquals(baseWallMillis, buckets.single().startUtcMillis)
        assertEquals(1.0, buckets.single().integratedSeconds, 1e-6)
    }

    @Test
    fun `samples without usable power are skipped without breaking the series`() {
        val samples = listOf(
            sample(0, 40f, packCurrentA = 100f),
            SessionAggregateSampleRow(
                elapsedRealtimeNanos = 2_000_000_000L,
                wallTimeUtcMillis = baseWallMillis + 1_000L,
                speedKmh = null,
                socPercent = null,
                odometerKm = null,
                voltageV = null,
                currentA = null,
                powerKw = null,
                freshnessMask = 0,
                canDrivePowerKw = null,
                canPackVoltageV = null,
                canPackCurrentA = null
            ),
            sample(2, 40f, packCurrentA = 100f)
        )

        val buckets = accumulate(samples)
        assertEquals(1, buckets.size)
        // The interval simply spans the unusable row rather than being dropped.
        assertEquals(2.0, buckets.single().integratedSeconds, 1e-6)
    }

    @Test
    fun `an empty or single-sample session reports nothing`() {
        assertTrue(accumulate(emptyList()).isEmpty())
        assertTrue(accumulate(listOf(sample(0, 40f, packCurrentA = 100f))).isEmpty())
    }

    @Test
    fun `alignment floors negative wall clocks instead of truncating toward zero`() {
        // Defensive: a device with an unset clock can report a pre-epoch time,
        // and integer division would round those buckets the wrong way.
        assertEquals(-60_000L, EnergyBucketAccumulator.alignToBucket(-1L))
        assertEquals(0L, EnergyBucketAccumulator.alignToBucket(0L))
        assertEquals(0L, EnergyBucketAccumulator.alignToBucket(59_999L))
        assertEquals(60_000L, EnergyBucketAccumulator.alignToBucket(60_000L))
    }

    @Test
    fun `combining trips adds the minute they share instead of choosing one`() {
        // A window can hold two trips that touch the same minute — one ending
        // at 13:39:20, the next starting at 13:39:50. Both really happened, so
        // the bar is their sum.
        val first = accumulate((0..20L).map { sample(it, 36f, packCurrentA = 90f) })
        val second = accumulate(
            (50..80L).map { sample(it, 36f, packCurrentA = 90f) }
        )

        val combined = EnergyBucketAccumulator.combine(listOf(first, second))

        // 13:39 is shared; 13:40 belongs to the second trip alone.
        assertEquals(2, combined.size)
        assertEquals(baseWallMillis, combined[0].startUtcMillis)
        assertEquals(
            first.first().integratedSeconds + second.first().integratedSeconds,
            combined[0].integratedSeconds,
            1e-9
        )
        assertEquals(
            first.sumOf { it.tractionWh } + second.sumOf { it.tractionWh },
            combined.sumOf { it.tractionWh },
            1e-9
        )
    }

    @Test
    fun `combining returns one sorted series`() {
        val later = accumulate((200..230L).map { sample(it, 36f, packCurrentA = 90f) })
        val earlier = accumulate((0..20L).map { sample(it, 36f, packCurrentA = 90f) })

        // Given out of order, as `inWindow` returns trips newest first.
        val combined = EnergyBucketAccumulator.combine(listOf(later, earlier))

        assertEquals(
            combined.map { it.startUtcMillis }.sorted(),
            combined.map { it.startUtcMillis }
        )
        assertTrue(combined.isNotEmpty())
    }

    @Test
    fun `combining nothing yields nothing`() {
        assertTrue(EnergyBucketAccumulator.combine(emptyList()).isEmpty())
        assertTrue(EnergyBucketAccumulator.combine(listOf(emptyList())).isEmpty())
    }

    @Test
    fun `auxiliary carries what the drivetrain did not`() {
        // pack - drive is the whole of the rest: climate, electronics, DC-DC.
        // It is one bucket by construction, and the chart must receive it as
        // one rather than pretending to know the split.
        val buckets = accumulate(
            (0..60L).map { second ->
                // 40 kW at the wheels, 42 kW out of the pack: 2 kW auxiliary.
                sample(second, 40f, packVoltageV = 400f, packCurrentA = 105f)
            }
        )

        val auxiliary = buckets.sumOf { it.auxiliaryWh }
        val seconds = buckets.sumOf { it.integratedSeconds }
        // 2 kW for 60 s is 33.3 Wh.
        assertEquals(60.0, seconds, 1e-6)
        assertTrue(abs(auxiliary - 2_000.0 * 60.0 / 3_600.0) < 1e-6)
    }

    @Test
    fun `a speed held across faster samples is integrated once`() {
        // The speed is the VHAL's, at 1 Hz, folded into CAN readings that
        // arrive at 60 Hz. Sixty samples carry the same reading, and it has to
        // count for the one second it describes rather than for sixty.
        val samples = (0 until 600).map { tick ->
            val nanos = (1_000_000_000L + tick * 100_000_000L / 6L)
            val speedSecond = tick / 60
            CanStreamSample(
                elapsedRealtimeNanos = nanos,
                wallTimeUtcMillis = baseWallMillis + tick * 100L / 6L,
                canDrivePowerKw = 36f,
                canPackVoltageV = 400f,
                canPackCurrentA = 90f,
                speedKmh = 36f,
                speedElapsedRealtimeNanos =
                    1_000_000_000L + speedSecond * 1_000_000_000L,
                speedWallTimeUtcMillis = baseWallMillis + speedSecond * 1_000L
            )
        }

        val accumulator = EnergyBucketAccumulator()
        samples.forEach(accumulator::add)
        val buckets = accumulator.result()

        // Nine seconds of speed, not ten: the last reading closes no interval
        // until the next one arrives. 36 km/h for 9 s is 90 m.
        assertEquals(9.0, buckets.sumOf { it.speedIntegratedSeconds }, 1e-6)
        assertEquals(0.09, buckets.sumOf { it.speedDistanceKm }, 1e-6)
    }

    @Test
    fun `a stale speed stops the distance without stopping the energy`() {
        // What the withdrawn CAN signal did every time it dropped out. The
        // integral must lose the distance term only. A bucket that keeps its
        // energy and loses its distance reads as a standstill, which is the
        // honest answer when the car stopped saying how fast it was going.
        val samples = (0 until 600).map { tick ->
            val nanos = 1_000_000_000L + tick * 100_000_000L / 6L
            // The speed stops advancing after five seconds; power does not.
            val speedSecond = minOf(tick / 60, 5)
            CanStreamSample(
                elapsedRealtimeNanos = nanos,
                wallTimeUtcMillis = baseWallMillis + tick * 100L / 6L,
                canDrivePowerKw = 36f,
                canPackVoltageV = 400f,
                canPackCurrentA = 90f,
                speedKmh = 36f,
                speedElapsedRealtimeNanos =
                    1_000_000_000L + speedSecond * 1_000_000_000L,
                speedWallTimeUtcMillis = baseWallMillis + speedSecond * 1_000L
            )
        }

        val accumulator = EnergyBucketAccumulator()
        samples.forEach(accumulator::add)
        val buckets = accumulator.result()

        assertEquals(5.0, buckets.sumOf { it.speedIntegratedSeconds }, 1e-6)
        assertEquals(0.05, buckets.sumOf { it.speedDistanceKm }, 1e-6)
        // The power integral ran across every sample regardless. 600 samples at
        // 60 Hz close 599 intervals, so 9.983 s and 36 kW of it.
        val powerSeconds = 599.0 / 60.0
        assertEquals(powerSeconds, buckets.sumOf { it.integratedSeconds }, 1e-3)
        assertEquals(
            36_000.0 * powerSeconds / 3_600.0,
            buckets.sumOf { it.tractionWh },
            1e-3
        )
    }

    /**
     * A reading that carries climate power, which only a live CAN sample does.
     * The persisted projections have no such column, so a swept trip has no
     * split — which is right, and is what `resampled` already tells the caller.
     */
    private fun climateSample(
        seconds: Long,
        driveKw: Float = 45f,
        packCurrentA: Float = 125f,
        climateKw: Float?
    ) = CanStreamSample(
        elapsedRealtimeNanos = (seconds + 1) * 1_000_000_000L,
        wallTimeUtcMillis = baseWallMillis + seconds * 1_000L,
        canDrivePowerKw = driveKw,
        canPackVoltageV = 400f,
        canPackCurrentA = packCurrentA,
        canClimatePowerKw = climateKw
    )

    @Test
    fun `climate energy is a named share of the remainder, not an addition`() {
        // 400 V x 125 A = 50 kW from the pack, 45 kW to the wheels, so the
        // remainder is 5 kW. The car says 2 kW of it is climate.
        val buckets = EnergyBucketAccumulator().run {
            add(climateSample(seconds = 0, climateKw = 2f))
            add(climateSample(seconds = 1, climateKw = 2f))
            result()
        }

        val bucket = buckets.single()
        val hoursOfOneSecond = 1.0 / 3_600.0
        assertEquals(5_000.0 * hoursOfOneSecond, bucket.auxiliaryWh, 1e-9)
        assertEquals(2_000.0 * hoursOfOneSecond, bucket.climateWh, 1e-9)
        // The remainder is untouched, so every total already computed from it
        // is the same number it was before the split existed.
        assertTrue(bucket.climateWh < bucket.auxiliaryWh)
        assertEquals(1.0, bucket.climateIntegratedSeconds, 1e-9)
        assertEquals(1.0, bucket.integratedSeconds, 1e-9)
    }

    @Test
    fun `an interval missing the reading at either end is not covered`() {
        // Three samples, two intervals. The climate reading stops after the
        // second, so the second interval has no reading at its far end and must
        // not be counted as covered — interpolating from one end would extend
        // the series over ground the signal did not report.
        val buckets = EnergyBucketAccumulator().run {
            add(climateSample(seconds = 0, climateKw = 2f))
            add(climateSample(seconds = 1, climateKw = 2f))
            add(climateSample(seconds = 2, climateKw = null))
            result()
        }

        val bucket = buckets.single()
        assertEquals(2.0, bucket.integratedSeconds, 1e-9)
        assertEquals(1.0, bucket.climateIntegratedSeconds, 1e-9)
        assertEquals(2_000.0 / 3_600.0, bucket.climateWh, 1e-9)
    }

    @Test
    fun `a trip with no climate reading divides nothing and loses nothing`() {
        val buckets = EnergyBucketAccumulator().run {
            add(climateSample(seconds = 0, climateKw = null))
            add(climateSample(seconds = 1, climateKw = null))
            result()
        }

        val bucket = buckets.single()
        assertEquals(0.0, bucket.climateWh, 1e-9)
        assertEquals(0.0, bucket.climateIntegratedSeconds, 1e-9)
        assertEquals(5_000.0 / 3_600.0, bucket.auxiliaryWh, 1e-9)
    }

    @Test
    fun `an interval split at a minute boundary splits its climate cover too`() {
        // The interval runs from 55 s to 63 s, so it crosses the boundary and
        // both minutes take their share of the cover: 5 s and 3 s.
        val accumulator = EnergyBucketAccumulator()
        accumulator.add(
            CanStreamSample(
                elapsedRealtimeNanos = 1_000_000_000L,
                wallTimeUtcMillis = baseWallMillis + 55_000L,
                canDrivePowerKw = 45f,
                canPackVoltageV = 400f,
                canPackCurrentA = 125f,
                canClimatePowerKw = 2f
            )
        )
        accumulator.add(
            CanStreamSample(
                elapsedRealtimeNanos = 9_000_000_000L,
                wallTimeUtcMillis = baseWallMillis + 63_000L,
                canDrivePowerKw = 45f,
                canPackVoltageV = 400f,
                canPackCurrentA = 125f,
                canClimatePowerKw = 2f
            )
        )
        val buckets = accumulator.result()

        assertEquals(2, buckets.size)
        assertEquals(5.0, buckets[0].climateIntegratedSeconds, 1e-6)
        assertEquals(3.0, buckets[1].climateIntegratedSeconds, 1e-6)
        // Cover follows the measured seconds into each minute, so the caller's
        // coverage test still passes on both of them.
        buckets.forEach {
            assertEquals(it.integratedSeconds, it.climateIntegratedSeconds, 1e-9)
        }
        assertEquals(
            2_000.0 * 8.0 / 3_600.0,
            buckets.sumOf { it.climateWh },
            1e-6
        )
    }

    @Test
    fun `default mode rejects sample with null drive power`() {
        val accumulator = EnergyBucketAccumulator()
        accumulator.add(
            CanStreamSample(
                elapsedRealtimeNanos = 1_000_000_000L,
                wallTimeUtcMillis = baseWallMillis,
                canDrivePowerKw = null,
                canPackVoltageV = 400f,
                canPackCurrentA = 10f
            )
        )
        accumulator.add(
            CanStreamSample(
                elapsedRealtimeNanos = 2_000_000_000L,
                wallTimeUtcMillis = baseWallMillis + 1_000L,
                canDrivePowerKw = null,
                canPackVoltageV = 400f,
                canPackCurrentA = 10f
            )
        )
        assertTrue(accumulator.result().isEmpty())
    }

    @Test
    fun `parked mode integrates pack power when drive power is missing`() {
        val accumulator = EnergyBucketAccumulator(allowMissingDriveAsZero = true)
        for (second in 0L..60L step 5L) {
            accumulator.add(
                CanStreamSample(
                    elapsedRealtimeNanos = (second + 1) * 1_000_000_000L,
                    wallTimeUtcMillis = baseWallMillis + second * 1_000L,
                    canDrivePowerKw = null,
                    canPackVoltageV = 400f,
                    canPackCurrentA = 10f
                )
            )
        }
        val buckets = accumulator.result()
        assertEquals(1, buckets.size)
        // 400 V * 10 A = 4.0 kW pack power over 60 seconds = 66.666 Wh
        assertEquals(0.0, buckets[0].tractionWh, 1e-6)
        assertEquals(0.0, buckets[0].regeneratedWh, 1e-6)
        assertEquals(4_000.0 * 60.0 / 3_600.0, buckets[0].auxiliaryWh, 1e-3)
        assertEquals(60.0, buckets[0].integratedSeconds, 1e-6)
    }

    @Test
    fun `retainLast drops buckets older than the kept tail`() {
        val accumulator = EnergyBucketAccumulator()
        // Five whole minutes of 1 Hz samples. 0..299 stays inside minute 4.
        for (second in 0L..299L) {
            accumulator.add(
                sample(seconds = second, driveKw = 40f, packCurrentA = 100f)
            )
        }
        assertEquals(5, accumulator.result().size)

        accumulator.retainLast(2)
        val kept = accumulator.result()
        assertEquals(2, kept.size)
        assertEquals(
            baseWallMillis + 3 * EnergyBucket.BUCKET_MILLIS,
            kept.first().startUtcMillis
        )
        assertEquals(
            baseWallMillis + 4 * EnergyBucket.BUCKET_MILLIS,
            kept.last().startUtcMillis
        )
    }

    @Test
    fun `a jumped wall is projected back onto the monotonic line`() {
        val accumulator = EnergyBucketAccumulator()
        val oldWallBase = 1_748_048_880_000L // 2025-05-23 22:08:00
        val newWallBase = 1_787_101_260_000L // 2026-08-18 22:01:00

        // 30 seconds of driving in 2025
        for (sec in 0L..30L) {
            accumulator.add(
                CanStreamSample(
                    elapsedRealtimeNanos = (sec + 1) * 1_000_000_000L,
                    wallTimeUtcMillis = oldWallBase + sec * 1000L,
                    canDrivePowerKw = 20f,
                    canPackVoltageV = 400f,
                    canPackCurrentA = 50f
                )
            )
        }

        // Clock jumps forward by ~450 days to 2026, next second of monotonic time (sec 31).
        // The accumulator cannot tell a glitch from an NTP correction, so it
        // trusts the session anchor and projects: no bucket may carry the
        // jumped 2026 wall (gb-continuous-mode finding F-C).
        for (sec in 31L..91L) {
            val offsetFromJump = sec - 31L
            accumulator.add(
                CanStreamSample(
                    elapsedRealtimeNanos = (sec + 1) * 1_000_000_000L,
                    wallTimeUtcMillis = newWallBase + offsetFromJump * 1000L,
                    canDrivePowerKw = 20f,
                    canPackVoltageV = 400f,
                    canPackCurrentA = 50f
                )
            )
        }

        val buckets = accumulator.result()
        // 92 contiguous seconds on the anchor line: the 22:08 and 22:09
        // minutes of 2025-05-23, with nothing stranded in 2026.

        assertEquals(2, buckets.size)
        assertEquals(oldWallBase, buckets.first().startUtcMillis)
        assertEquals(oldWallBase + EnergyBucket.BUCKET_MILLIS, buckets.last().startUtcMillis)
        for (b in buckets) {
            assertTrue(
                "Bucket start ${b.startUtcMillis} should stay on the 2025 line (< 1.78e12), but was not",
                b.startUtcMillis < 1_780_000_000_000L
            )
        }
    }

    @Test
    fun `a closed bucket carries the state of charge at its start and at its end`() {
        val samples = (0..59L).map { sec ->
            val soc = when (sec) {
                0L -> 50.0f
                30L -> 49.8f
                59L -> 49.5f
                else -> null
            }
            sample(sec, 36f, packCurrentA = 90f, socPercent = soc)
        }

        val buckets = accumulate(samples)
        assertEquals(1, buckets.size)
        val bucket = buckets.single()
        assertEquals(50.0, bucket.startSoc!!, 1e-6)
        assertEquals(49.5, bucket.endSoc!!, 1e-6)
    }

    @Test
    fun `a bucket with no reading says so rather than reporting a default`() {
        val samples = listOf(
            sample(0, 36f, packCurrentA = 90f, socPercent = null),
            sample(1, 36f, packCurrentA = 90f, socPercent = null)
        )

        val buckets = accumulate(samples)
        assertEquals(1, buckets.size)
        val bucket = buckets.single()
        org.junit.Assert.assertNull(bucket.startSoc)
        org.junit.Assert.assertNull(bucket.endSoc)
    }

    @Test
    fun `a bucket with a single reading reports the same value at start and end`() {
        val samples = listOf(
            sample(0, 36f, packCurrentA = 90f, socPercent = null),
            sample(1, 36f, packCurrentA = 90f, socPercent = 48.0f)
        )

        val buckets = accumulate(samples)
        assertEquals(1, buckets.size)
        val bucket = buckets.single()
        assertEquals(48.0, bucket.startSoc!!, 1e-6)
        assertEquals(48.0, bucket.endSoc!!, 1e-6)
    }

    @Test
    fun `combining buckets preserves earliest startSoc and latest endSoc`() {
        val first = accumulate(listOf(
            sample(0, 36f, packCurrentA = 90f, socPercent = 50.0f),
            sample(1, 36f, packCurrentA = 90f, socPercent = 49.9f)
        ))
        val second = accumulate(listOf(
            sample(2, 36f, packCurrentA = 90f, socPercent = 49.8f),
            sample(3, 36f, packCurrentA = 90f, socPercent = 49.6f)
        ))

        val combined = EnergyBucketAccumulator.combine(listOf(first, second))
        assertEquals(1, combined.size)
        assertEquals(50.0, combined.single().startSoc!!, 1e-3)
        assertEquals(49.6, combined.single().endSoc!!, 1e-3)
    }

    @Test
    fun `projected walls across a clock jump preserve startSoc and endSoc`() {
        val accumulator = EnergyBucketAccumulator()
        val oldWallBase = 1_748_048_880_000L // 2025-05-23 22:08:00
        val newWallBase = 1_787_101_260_000L // 2026-08-18 22:01:00

        for (sec in 0L..30L) {
            accumulator.add(
                CanStreamSample(
                    elapsedRealtimeNanos = (sec + 1) * 1_000_000_000L,
                    wallTimeUtcMillis = oldWallBase + sec * 1000L,
                    canDrivePowerKw = 20f,
                    canPackVoltageV = 400f,
                    canPackCurrentA = 50f,
                    socPercent = 75.0f
                )
            )
        }

        for (sec in 31L..60L) {
            val offsetFromJump = sec - 31L
            accumulator.add(
                CanStreamSample(
                    elapsedRealtimeNanos = (sec + 1) * 1_000_000_000L,
                    wallTimeUtcMillis = newWallBase + offsetFromJump * 1000L,
                    canDrivePowerKw = 20f,
                    canPackVoltageV = 400f,
                    canPackCurrentA = 50f,
                    socPercent = 74.0f
                )
            )
        }

        val buckets = accumulator.result()
        assertTrue(buckets.isNotEmpty())
        assertEquals(75.0, buckets.first().startSoc!!, 1e-6)
        assertEquals(74.0, buckets.last().endSoc!!, 1e-6)
    }

    @Test
    fun `a bucket records earliest and latest pack voltage`() {
        val samples = listOf(
            sample(0, 36f, packVoltageV = 380f, packCurrentA = 90f),
            sample(1, 36f, packVoltageV = 382f, packCurrentA = 90f),
            sample(2, 36f, packVoltageV = 385f, packCurrentA = 90f)
        )

        val buckets = accumulate(samples)
        assertEquals(1, buckets.size)
        val bucket = buckets.single()
        assertEquals(380.0, bucket.startVoltage!!, 1e-6)
        assertEquals(385.0, bucket.endVoltage!!, 1e-6)
    }

    @Test
    fun `combining buckets preserves earliest startVoltage and latest endVoltage`() {
        val first = accumulate(listOf(
            sample(0, 36f, packVoltageV = 380f, packCurrentA = 90f),
            sample(1, 36f, packVoltageV = 382f, packCurrentA = 90f)
        ))
        val second = accumulate(listOf(
            sample(2, 36f, packVoltageV = 383f, packCurrentA = 90f),
            sample(3, 36f, packVoltageV = 385f, packCurrentA = 90f)
        ))

        val combined = EnergyBucketAccumulator.combine(listOf(first, second))
        assertEquals(1, combined.size)
        assertEquals(380.0, combined.single().startVoltage!!, 1e-3)
        assertEquals(385.0, combined.single().endVoltage!!, 1e-3)
    }

    @Test
    fun `projected walls across a clock jump preserve startVoltage and endVoltage`() {
        val accumulator = EnergyBucketAccumulator()
        val oldWallBase = 1_748_048_880_000L // 2025-05-23 22:08:00
        val newWallBase = 1_787_101_260_000L // 2026-08-18 22:01:00

        for (sec in 0L..30L) {
            accumulator.add(
                CanStreamSample(
                    elapsedRealtimeNanos = (sec + 1) * 1_000_000_000L,
                    wallTimeUtcMillis = oldWallBase + sec * 1000L,
                    canDrivePowerKw = 20f,
                    canPackVoltageV = 380f,
                    canPackCurrentA = 50f
                )
            )
        }

        for (sec in 31L..60L) {
            val offsetFromJump = sec - 31L
            accumulator.add(
                CanStreamSample(
                    elapsedRealtimeNanos = (sec + 1) * 1_000_000_000L,
                    wallTimeUtcMillis = newWallBase + offsetFromJump * 1000L,
                    canDrivePowerKw = 20f,
                    canPackVoltageV = 385f,
                    canPackCurrentA = 50f
                )
            )
        }

        val buckets = accumulator.result()
        assertTrue(buckets.isNotEmpty())
        assertEquals(380.0, buckets.first().startVoltage!!, 1e-6)
        assertEquals(385.0, buckets.last().endVoltage!!, 1e-6)
    }

    /**
     * `CONTINUOUS` and `PARKED` run this accumulator in its normal mode across
     * both driving and charging. Before issue 199/211's fix, a charging minute
     * had no real drive power to subtract from `packKw`, so the negative
     * (charging) pack reading fell into `auxiliaryWh` — a field the rest of the
     * app only ever expects to be a small positive accessory draw.
     */
    @Test
    fun `a charging minute records delivered energy, not negative auxiliary`() {
        val accumulator = EnergyBucketAccumulator(allowMissingDriveAsZero = true)

        // 400 V at -20 A is an 8 kW charge; no drive power, as while plugged in.
        (0..30L).forEach { second ->
            accumulator.add(
                sample(seconds = second, driveKw = 0f, packCurrentA = -20f),
                isCharging = true
            )
        }

        val bucket = accumulator.result().single()
        assertEquals("30 s at 8 kW", 8_000.0 * 30.0 / 3_600.0, bucket.deliveredWh, 1e-6)
        assertEquals(0.0, bucket.auxiliaryWh, 1e-9)
        assertEquals(0.0, bucket.tractionWh, 1e-9)
        assertEquals(0.0, bucket.regeneratedWh, 1e-9)
    }

    @Test
    fun `a charging minute leaves an earlier driving minute in the same accumulator untouched`() {
        // A CONTINUOUS session that drives, then plugs in: the trip minute must
        // keep reading traction/auxiliary the normal way, and only the later,
        // charging minute should carry delivered energy.
        val accumulator = EnergyBucketAccumulator(allowMissingDriveAsZero = true)

        (0..30L).forEach { second ->
            accumulator.add(sample(seconds = second, driveKw = 20f, packCurrentA = 60f))
        }
        (60..90L).forEach { second ->
            accumulator.add(
                sample(seconds = second, driveKw = 0f, packCurrentA = -20f),
                isCharging = true
            )
        }

        val buckets = accumulator.result()
        val driving = buckets.first()
        val charging = buckets.last()

        assertTrue("the driving minute must keep its traction", driving.tractionWh > 0.0)
        assertEquals(0.0, driving.deliveredWh, 1e-9)
        assertTrue("the charging minute must carry delivered energy", charging.deliveredWh > 0.0)
        assertEquals(0.0, charging.auxiliaryWh, 1e-9)
        assertEquals(0.0, charging.tractionWh, 1e-9)
    }

    @Test
    fun `a wild odometer reading is dropped, not integrated`() {
        // Live-DB finding F-B: one bad odometer sample thousands of km off
        // landed verbatim on the minute's distanceKm (36 continuous rows,
        // ~131,092 km of phantom distance, SOC flat while "distance"
        // explodes). The implausible step must record no distance — and the
        // stream must keep going: the baseline advances past the bad reading
        // so the next good step deltas cleanly instead of wedging later
        // minutes at zero. A clamped-but-wrong number is still wrong, so the
        // step is dropped, never clamped to the ceiling.
        val accumulator = EnergyBucketAccumulator()
        val at = { second: Long, odo: Double ->
            sample(
                seconds = second,
                driveKw = 10f,
                packCurrentA = 25f,
                odometerKm = odo.toFloat()
            )
        }
        accumulator.add(at(0, 100.0))
        accumulator.add(at(1, 100.01))
        // High glitch: +7,395 km in one second. Records nothing.
        accumulator.add(at(2, 7_495.61))
        // Recovery: the drive after the glitch still counts. The step back
        // down off the glitch is negative and drops too — losing one real
        // second of driving is the price of not integrating the glitch.
        accumulator.add(at(3, 100.02))
        accumulator.add(at(4, 100.03))

        val buckets = accumulator.result()
        assertEquals(
            0.02,
            buckets.sumOf { it.odometerDistanceKm },
            1e-4
        )
    }

    @Test
    fun `a bucket carries the pair of the sample that opened it, not the flush instant`() {
        // T2: the subtraction the later correction runs is exact only when
        // the pair beside the wall stamp is the monotonic reading of the
        // same instant. Stamping flush time would move the minute onto a
        // younger reading by the whole flush delay. Each bucket is born from
        // the first slice that reaches it, so the first bucket is stamped
        // with the second folded sample (the first closes no slice) and the
        // second bucket with the sample whose slice first crosses :40.
        val accumulator = EnergyBucketAccumulator()
        (10..70L).forEach { second ->
            accumulator.add(
                sample(seconds = second, driveKw = 40f, packCurrentA = 100f),
                bootCount = 41
            )
        }

        val buckets = accumulator.result()
        assertEquals(2, buckets.size)
        assertEquals(11_000_000_000L, buckets[0].startElapsedNanos)
        assertEquals(41, buckets[0].startBootCount)
        assertEquals(61_000_000_000L, buckets[1].startElapsedNanos)
        assertEquals(41, buckets[1].startBootCount)
    }

    @Test
    fun `a reboot mid-trip stamps each boot's buckets with their own boot`() {
        // T2: the elapsed axis restarts on reboot, so one boot's reading
        // means nothing on another boot's axis. Buckets folded after the
        // restart must carry the new count; stamping the current boot onto
        // everything would credit the old minutes to the new axis.
        val accumulator = EnergyBucketAccumulator()
        (10..50L).forEach { second ->
            accumulator.add(
                sample(seconds = second, driveKw = 40f, packCurrentA = 100f),
                bootCount = 41
            )
        }
        // The reboot: elapsed restarts near zero on boot 42 while the wall
        // clock keeps walking into the next minute.
        (51..110L).forEach { second ->
            accumulator.add(
                sample(
                    seconds = second,
                    driveKw = 40f,
                    packCurrentA = 100f,
                    wallOffsetMillis = 61_000L + (second - 51) * 1_000L
                ).copy(elapsedRealtimeNanos = (second - 50) * 1_000_000_000L),
                bootCount = 42
            )
        }

        val buckets = accumulator.result()
        assertEquals(2, buckets.size)
        assertEquals(11_000_000_000L, buckets[0].startElapsedNanos)
        assertEquals(41, buckets[0].startBootCount)
        assertEquals(1_000_000_000L, buckets[1].startElapsedNanos)
        assertEquals(42, buckets[1].startBootCount)
    }

    @Test
    fun `toEntity carries the bucket pair onto the stored row`() {
        // T2: the columns T1 added stay null unless this mapping fills them.
        val bucket = EnergyBucket(
            startUtcMillis = baseWallMillis,
            startElapsedNanos = 11_000_000_000L,
            startBootCount = 41
        )

        val row = bucket.toEntity("trip-1", updatedAtUtcMillis = 0L)

        assertEquals(11_000_000_000L, row.startElapsedNanos)
        assertEquals(41, row.startBootCount)
    }

    @Test
    fun `a bucket with a gap after opening carries the first sample, not the delayed second sample`() {
        // T2 Risk 1: if the pair came from the sample that triggered slice integration
        // or getOrCreateBucket, any delay between the opening sample and subsequent samples
        // would move the minute onto a younger reading by the whole gap delay.
        val accumulator = EnergyBucketAccumulator()
        accumulator.add(
            sample(seconds = 10, driveKw = 40f, packCurrentA = 100f),
            bootCount = 41
        )
        accumulator.add(
            sample(seconds = 15, driveKw = 40f, packCurrentA = 100f),
            bootCount = 41
        )
        accumulator.add(
            sample(seconds = 20, driveKw = 40f, packCurrentA = 100f),
            bootCount = 41
        )

        val buckets = accumulator.result()
        assertEquals(1, buckets.size)
        assertEquals(11_000_000_000L, buckets[0].startElapsedNanos)
        assertEquals(41, buckets[0].startBootCount)
    }

    @Test
    fun `deliveredOnly charging accumulator carries the first sample monotonic pair`() {
        val accumulator = EnergyBucketAccumulator(deliveredOnly = true)
        accumulator.add(
            sample(seconds = 10, driveKw = 0f, packCurrentA = -50f),
            bootCount = 7
        )
        accumulator.add(
            sample(seconds = 20, driveKw = 0f, packCurrentA = -50f),
            bootCount = 7
        )

        val buckets = accumulator.result()
        assertEquals(1, buckets.size)
        assertEquals(11_000_000_000L, buckets[0].startElapsedNanos)
        assertEquals(7, buckets[0].startBootCount)
    }

    @Test
    fun `retainLast cleans up pending endpoints when older buckets are pruned`() {
        val accumulator = EnergyBucketAccumulator()
        (0..180L step 60).forEach { second ->
            accumulator.add(
                sample(seconds = second, driveKw = 40f, packCurrentA = 100f),
                bootCount = 10
            )
            accumulator.add(
                sample(seconds = second + 1, driveKw = 40f, packCurrentA = 100f),
                bootCount = 10
            )
        }
        accumulator.retainLast(1)
        val buckets = accumulator.result()
        assertEquals(1, buckets.size)
        assertEquals(baseWallMillis + 180_000L, buckets[0].startUtcMillis)
        assertEquals(181_000_000_000L, buckets[0].startElapsedNanos)
        assertEquals(10, buckets[0].startBootCount)
    }
}
