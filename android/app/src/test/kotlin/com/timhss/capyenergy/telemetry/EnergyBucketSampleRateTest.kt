package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.CanStreamSample
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.random.Random
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Why the auxiliary integral runs at bus rate rather than at frame rate.
 *
 * Auxiliary power is the remainder `pack - drive`. Both operands swing to tens
 * of kW while the remainder sits near half a kW, and they do not arrive on the
 * same CAN frame — `BMSH_BattCurr` is `0x250`, `VCU_DrvPwrAct` is `0x315` — so
 * a reader sees each one some age after the value it reports. That age is not a
 * fixed lag that would cancel: the poll is asynchronous to the bus, so it
 * lands somewhere in the polling interval afresh every time. Independent jitter
 * on two large operands becomes noise on their small difference, proportional
 * to how fast the drivetrain is moving.
 *
 * Measured on the 2026-08-05 drives, integrating persisted 1 Hz rows put 25 %
 * of samples below zero — auxiliaries do not generate power — and left two
 * half-rate phases of the same trip disagreeing about its total by 176 %. The
 * per-minute bars the chart draws averaged 6.1 Wh with a 10.8 Wh disagreement.
 *
 * The fix works on both terms at once: polling at 60 Hz instead of 10 Hz cuts
 * the staleness that creates the noise, and integrating every poll instead of
 * every persisted frame gives each minute 3 600 samples to average it over
 * rather than 60.
 */
class EnergyBucketSampleRateTest {

    /** 2026-08-05T17:15:00Z, on a minute boundary. */
    private val baseWallMillis = 1_785_690_900_000L

    private val auxiliaryKw = 0.6
    private val packVoltage = 395.0
    private val durationSeconds = 600
    private val truthWhPerMinute = auxiliaryKw * 60 / 3.6

    /**
     * A drivetrain that moves the way one does: a slow speed profile with pedal
     * and torque-control activity on top.
     */
    private fun driveKw(t: Double): Double =
        35.0 * sin(2 * PI * 0.11 * t) +
            12.0 * sin(2 * PI * 0.63 * t + 1.0) +
            6.0 * sin(2 * PI * 1.70 * t + 2.0)

    /**
     * Integrates the trip the way a given reader would see it.
     *
     * [pollHz] sets how stale each operand can be when it is read, because a
     * shared-memory value is only as fresh as the last poll. [gridHz] sets how
     * often that reading is folded into the integral. Today's pipeline is a
     * 10 Hz poll folded on a 1 Hz grid; the fix reads and folds at 60 Hz.
     */
    private fun auxiliaryPerMinute(pollHz: Int, gridHz: Int, seed: Int = 7): List<Double> {
        val random = Random(seed)
        val staleness = 1.0 / pollHz
        val accumulator = EnergyBucketAccumulator()
        for (step in 0..(durationSeconds * gridHz)) {
            val t = step.toDouble() / gridHz
            val packAge = random.nextDouble(staleness)
            val driveAge = random.nextDouble(staleness)
            val packKw = driveKw(t - packAge) + auxiliaryKw
            accumulator.add(
                CanStreamSample(
                    elapsedRealtimeNanos = ((t + 1.0) * 1_000_000_000L).toLong(),
                    wallTimeUtcMillis = baseWallMillis + (t * 1_000.0).toLong(),
                    canDrivePowerKw = driveKw(t - driveAge).toFloat(),
                    canPackVoltageV = packVoltage.toFloat(),
                    // The integral rebuilds pack power as V * I, so hand it the
                    // current that produces this pack power.
                    canPackCurrentA = (packKw * 1_000.0 / packVoltage).toFloat()
                )
            )
        }
        // The first and last minutes are partial by construction; the chart
        // marks those as still filling rather than reading them as a dip.
        return accumulator.result()
            .filter { it.integratedSeconds > 59.0 }
            .map { it.auxiliaryWh }
    }

    private fun worstMinuteError(minutes: List<Double>): Double =
        minutes.maxOf { abs(it - truthWhPerMinute) } / truthWhPerMinute

    @Test
    fun `bus rate recovers the auxiliary load in every minute`() {
        val minutes = auxiliaryPerMinute(pollHz = 60, gridHz = 60)
        val error = worstMinuteError(minutes)

        assertTrue(
            "every minute should land within 8 % of $truthWhPerMinute Wh, " +
                "worst was ${(error * 100).toInt()} % off across $minutes",
            error < 0.08
        )
    }

    @Test
    fun `frame rate does not`() {
        // The guard on the change: were the old rate good enough, there would be
        // no reason to integrate off the Roadcast stream at all.
        val minutes = auxiliaryPerMinute(pollHz = 10, gridHz = 1)
        val error = worstMinuteError(minutes)

        assertTrue(
            "a 10 Hz poll folded once a second is expected to miss badly; it " +
                "returned $minutes against $truthWhPerMinute Wh a minute, " +
                "which is close enough to question this test",
            error > 0.40
        )
    }

    @Test
    fun `the result no longer depends on which samples happen to be picked`() {
        // The convergence test that failed on the recorded data: an estimator is
        // only trustworthy once refining the grid stops changing the answer.
        val full = auxiliaryPerMinute(pollHz = 60, gridHz = 60).sum()
        val half = auxiliaryPerMinute(pollHz = 60, gridHz = 30).sum()

        val disagreement = abs(full - half) / abs(full)
        assertTrue(
            "60 Hz and 30 Hz should agree within 2 %, got $full Wh and $half Wh",
            disagreement < 0.02
        )
    }

    @Test
    fun `bus rate holds up whatever the sampling phase turns out to be`() {
        // One lucky seed would prove nothing: the phase between poll and bus is
        // arbitrary on every drive.
        repeat(8) { seed ->
            val error = worstMinuteError(auxiliaryPerMinute(pollHz = 60, gridHz = 60, seed = seed))
            assertTrue(
                "seed $seed drifted ${(error * 100).toInt()} % from the load",
                error < 0.08
            )
        }
    }

    @Test
    fun `no minute reports the auxiliaries generating power`() {
        // A quarter of the recorded 1 Hz samples came out below zero, and so did
        // whole minutes of the chart.
        val minutes = auxiliaryPerMinute(pollHz = 60, gridHz = 60)
        assertTrue(
            "no minute should report negative auxiliary energy, got $minutes",
            minutes.all { it > 0.0 }
        )
    }
}
