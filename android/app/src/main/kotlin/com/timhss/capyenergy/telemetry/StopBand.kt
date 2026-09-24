package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile

/**
 * When the vehicle counts as standing, and when it counts as moving again.
 *
 * Two thresholds with a gap between them, so a vehicle creeping inside the gap
 * does not flip side on every reading. The side is the one the last accepted
 * reading stood on.
 *
 * This is one rule with two readers. [PositionDeadbandEvaluator] spends it to
 * decide that a position tuple has earned a row, and [TrackRecorder] spends it
 * to decide that a point is one end of a stop and must survive simplification.
 * Both see exactly the same readings — the recorder is fed only the points the
 * evaluator wrote — so both walk the same side sequence. A second copy of the
 * rule would be a second answer to "is the car stopped".
 *
 * See issue 177 for why the speed comes from the bus and not from the fix, and
 * issue 178 for the protection.
 */
object StopBand {
    const val STANDING_KMH = GeelyProfile.POSITION_STANDING_SPEED_KMH
    const val MOVING_KMH = GeelyProfile.POSITION_MOVING_SPEED_KMH

    /**
     * True when [speedKmh] leaves the side [wasStanding] names.
     *
     * A null speed answers false: with nothing measured there is no crossing,
     * and the caller's other rules decide alone.
     */
    fun crosses(
        wasStanding: Boolean?,
        speedKmh: Double?,
        standingKmh: Double = STANDING_KMH,
        movingKmh: Double = MOVING_KMH
    ): Boolean = when {
        speedKmh == null -> false
        wasStanding == true -> speedKmh >= movingKmh
        else -> speedKmh <= standingKmh
    }

    /**
     * The side to keep after accepting [speedKmh].
     *
     * Inside the band the side does not change: that is the hysteresis. A first
     * reading inside it has no side to keep and counts as moving, because the
     * vehicle is above the standing threshold.
     */
    fun nextStanding(
        wasStanding: Boolean?,
        speedKmh: Double?,
        standingKmh: Double = STANDING_KMH,
        movingKmh: Double = MOVING_KMH
    ): Boolean? = when {
        speedKmh == null -> wasStanding
        speedKmh <= standingKmh -> true
        speedKmh >= movingKmh || wasStanding == null -> false
        else -> wasStanding
    }
}
