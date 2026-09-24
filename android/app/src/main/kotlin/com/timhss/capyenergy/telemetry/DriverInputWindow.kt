package com.timhss.capyenergy.telemetry

/**
 * The driver's inputs over the second one frame covers.
 *
 * Frames are written once a second, and the Roadcast stream arrives at 60. Two
 * of the Signal Lab stage 1 columns lose their meaning under a point sample at
 * that ratio:
 *
 *  * `ESC_BrakePedalSwitchStatus` is an edge. A tap is often shorter than the
 *    gap between frames, so sampling the tick reports the pedal up for the
 *    whole second in which it went down and came back. The friction-brake
 *    estimator of `lib/core/physics_model.dart` is gated on this column, and a
 *    gate that misses the press withholds the estimate exactly when there was
 *    something to estimate.
 *  * `VCU_AccelPedalPosition` at one instant is not the second's demand. The
 *    mean is, and it is the same reduction the rest of the row already uses.
 *
 * Nothing else is folded, and that is deliberate. Every other new column is
 * either a slow setting, or a value stored beside the raw count it was decoded
 * from. Folding one of those pairs would break the identity that makes the
 * count worth keeping: `canDrivePowerKw - canDrivePowerRaw x 0.1` must equal
 * the daemon's offset on every row, which is what lets a scale found next month
 * be re-checked against this month's drives. A mean of counts beside a mean of
 * values holds that identity only up to the rounding of the count, and the
 * `drivetrain` lens reads the residual at a tolerance finer than that rounding.
 * So the pairs stay coherent instants, and only the two inputs are reduced.
 *
 * [observe] runs on the Roadcast monitor thread and [drain] on the collector
 * thread, so both are synchronized. The window is small and uncontended: one
 * boolean and two numbers, touched 60 times a second.
 */
class DriverInputWindow {

    /** What one second of the bus said about the driver. */
    data class Inputs(
        /**
         * Whether the pedal went down at any point in the window.
         *
         * Null when no sample in the window reported the switch at all, which
         * is a different fact from a second in which nobody braked.
         */
        val brakePressed: Boolean?,
        /** Mean pedal position over the window, or null when none arrived. */
        val accelPedalPercent: Float?,
    ) {
        companion object {
            val empty = Inputs(brakePressed = null, accelPedalPercent = null)
        }
    }

    private var brakeReported = false
    private var brakePressed = false
    private var accelSum = 0.0
    private var accelCount = 0

    /** Folds one CAN reading in. */
    @Synchronized
    fun observe(metrics: RoadcastTripMetrics) {
        metrics.brakePedalOn?.let { pressed ->
            brakeReported = true
            // Any press in the window is a press in the window. The column
            // answers whether the driver braked during that second, and the
            // last sample of the second cannot answer it.
            if (pressed) brakePressed = true
        }
        metrics.accelPedalPercent?.let { percent ->
            if (percent.isFinite()) {
                accelSum += percent.toDouble()
                accelCount++
            }
        }
    }

    /**
     * Takes the window and starts a new one.
     *
     * Draining is what bounds the window to one frame. A read that left the
     * state behind would let a press reported once go on being reported for
     * the rest of the trip.
     */
    @Synchronized
    fun drain(): Inputs {
        val inputs = Inputs(
            brakePressed = if (brakeReported) brakePressed else null,
            accelPedalPercent = if (accelCount > 0) {
                (accelSum / accelCount).toFloat()
            } else {
                null
            },
        )
        clear()
        return inputs
    }

    /** Discards the window without reading it. */
    @Synchronized
    fun reset() = clear()

    private fun clear() {
        brakeReported = false
        brakePressed = false
        accelSum = 0.0
        accelCount = 0
    }
}
