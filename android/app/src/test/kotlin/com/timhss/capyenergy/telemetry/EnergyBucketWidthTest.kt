package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The finer cut has to be the same integral, only sliced differently.
 *
 * The efficiency card reads ten-second buckets while the chart and the session
 * summary read minutes. If those two could disagree about the same driving, the
 * app would be reporting two answers for one trip — the exact failure the single
 * accumulator exists to prevent. These tests hold the two cuts together.
 */
class EnergyBucketWidthTest {

    /** 2026-08-03T13:39:00Z, already on a minute boundary. */
    private val baseWallMillis = 1_785_505_140_000L

    private fun sample(
        seconds: Long,
        driveKw: Float,
        packCurrentA: Float,
        speedKmh: Float?
    ) = SessionAggregateSampleRow(
        elapsedRealtimeNanos = (seconds + 1) * 1_000_000_000L,
        wallTimeUtcMillis = baseWallMillis + seconds * 1_000L,
        speedKmh = speedKmh,
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

    /**
     * Three minutes of driving that changes throughout, so a cut that lost or
     * misplaced energy could not hide behind a constant.
     */
    private fun drive(): List<SessionAggregateSampleRow> =
        (0..180L).map { second ->
            val driveKw = when {
                second in 40..55 -> -30f + second // braking into regeneration
                second % 17 == 0L -> 90f
                else -> 20f + (second % 23)
            }
            sample(
                seconds = second,
                driveKw = driveKw,
                packCurrentA = 60f + (second % 31),
                speedKmh = if (second in 100..115) 0f else 30f + (second % 41)
            )
        }

    private fun accumulate(width: Long): List<EnergyBucket> {
        val accumulator = EnergyBucketAccumulator(width)
        drive().forEach(accumulator::add)
        return accumulator.result()
    }

    @Test
    fun `ten-second buckets sum back to the minute, field for field`() {
        val minutes = accumulate(EnergyBucket.BUCKET_MILLIS)
        val tenSeconds = accumulate(10_000L)

        assertTrue("expected several minutes", minutes.size >= 3)
        assertEquals(minutes.size * 6, tenSeconds.size)

        for (minute in minutes) {
            val slices = tenSeconds.filter {
                it.startUtcMillis >= minute.startUtcMillis &&
                    it.startUtcMillis < minute.startUtcMillis + EnergyBucket.BUCKET_MILLIS
            }
            assertEquals(6, slices.size)
            val label = "minute ${minute.startUtcMillis}"
            assertEquals(label, minute.tractionWh, slices.sumOf { it.tractionWh }, 1e-9)
            assertEquals(label, minute.regeneratedWh, slices.sumOf { it.regeneratedWh }, 1e-9)
            assertEquals(label, minute.auxiliaryWh, slices.sumOf { it.auxiliaryWh }, 1e-9)
            assertEquals(
                label,
                minute.integratedSeconds,
                slices.sumOf { it.integratedSeconds },
                1e-9
            )
            assertEquals(
                label,
                minute.speedDistanceKm,
                slices.sumOf { it.speedDistanceKm },
                1e-9
            )
        }
    }

    @Test
    fun `every width divides the trip into the same totals`() {
        val minuteTotal = accumulate(EnergyBucket.BUCKET_MILLIS).sumOf { it.tractionWh }

        for (width in listOf(1_000L, 10_000L, 15_000L, 30_000L)) {
            assertEquals(
                "width $width",
                minuteTotal,
                accumulate(width).sumOf { it.tractionWh },
                1e-9
            )
        }
    }

    @Test
    fun `ten-second buckets align to the wall clock, not to the first sample`() {
        assertTrue(
            accumulate(10_000L).all { it.startUtcMillis % 10_000L == 0L }
        )
    }

    @Test
    fun `a standstill inside a minute is visible at ten seconds and hidden at sixty`() {
        // Seconds 100..115 are stopped. The minute holding them still reports
        // distance from the moving seconds either side, so only the finer cut
        // can show the card that the car was not moving.
        val minutes = accumulate(EnergyBucket.BUCKET_MILLIS)
        val tenSeconds = accumulate(10_000L)

        assertTrue(minutes.all { it.speedDistanceKm > 0.0 })
        assertTrue(tenSeconds.any { it.speedDistanceKm == 0.0 })
    }

    @Test
    fun `the charge climate window is one minute of reconcilable buckets`() {
        // The warning compares the climate draw with the charge rate, so it
        // reads a window it can cross in about a minute. Read over the stored
        // minute monitor, whose window is three minutes, the warning lagged the
        // climate control by the width of that window.
        assertEquals(
            0L,
            EnergyBucket.BUCKET_MILLIS % FrameRepository.CHARGE_CLIMATE_BUCKET_MILLIS
        )
        assertEquals(
            EnergyBucket.BUCKET_MILLIS,
            FrameRepository.CHARGE_CLIMATE_BUCKET_MILLIS *
                FrameRepository.CHARGE_CLIMATE_WINDOW_BUCKETS
        )
    }

    @Test
    fun `a width that does not divide the minute is refused`() {
        // Buckets that straddle a minute boundary could never be reconciled
        // with the stored series, so the constructor rejects them outright
        // rather than producing a plausible series that quietly disagrees.
        assertThrows(IllegalArgumentException::class.java) {
            EnergyBucketAccumulator(7_000L)
        }
        assertThrows(IllegalArgumentException::class.java) {
            EnergyBucketAccumulator(0L)
        }
    }
}
