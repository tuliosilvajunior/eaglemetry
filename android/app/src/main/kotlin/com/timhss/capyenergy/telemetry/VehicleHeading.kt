package com.timhss.capyenergy.telemetry

/**
 * Why the vehicle heading is, or is not, a number.
 *
 * The car has no usable magnetometer, so the only heading source is the GNSS
 * course over ground. That course exists only while the vehicle moves. A
 * standstill is therefore a normal state, not a fault, and it must be told
 * apart from a fault: [NO_BEARING] is a car that is stopped, [NO_FIX] is a
 * receiver that sees nothing, and [PERMISSION_MISSING] is this app.
 */
enum class HeadingAvailability {
    /** The fix carries a course. */
    OK,

    /** The user turned GPS collection off in the app settings. */
    GPS_DISABLED,

    /** Android did not grant a location permission. */
    PERMISSION_MISSING,

    /** No provider is enabled, or no fix has arrived yet. */
    NO_FIX,

    /** The last fix is older than the age limit. */
    FIX_STALE,

    /**
     * There is a fresh fix, but it carries no course. This is what a stopped
     * vehicle looks like.
     */
    NO_BEARING,
}

/**
 * The GNSS course over ground, with everything a reader needs to judge it.
 *
 * This type states what the receiver reported. It applies no movement floor
 * and no smoothing: those are display rules, they need memory of earlier
 * readings, and they belong to the Flutter side that draws the compass.
 *
 * [bearingDeg] is the direction of travel, not the direction the vehicle
 * points. The two differ in reverse and during a manoeuvre. Nothing here can
 * tell them apart, so nothing here claims to.
 */
data class VehicleHeading(
    val timestampMillis: Long,
    val availability: HeadingAvailability,
    val bearingDeg: Double?,
    val bearingAccuracyDeg: Double?,
    val speedMps: Double?,
    val fixAgeMillis: Long?,
) {
    companion object {
        /**
         * The judgement, over plain values, so it can be tested without a
         * `Location` and without Android.
         *
         * A bearing survives only when every condition holds. The reason for a
         * refusal is reported in the order the conditions are checked, from
         * the widest cause to the narrowest, so the answer names the first
         * thing to fix.
         */
        fun resolve(
            timestampMillis: Long,
            gpsEnabled: Boolean,
            permissionGranted: Boolean,
            hasFix: Boolean,
            fixAgeMillis: Long?,
            maxFixAgeMillis: Long,
            bearingDeg: Double?,
            bearingAccuracyDeg: Double?,
            speedMps: Double?,
        ): VehicleHeading {
            val availability = when {
                !gpsEnabled -> HeadingAvailability.GPS_DISABLED
                !permissionGranted -> HeadingAvailability.PERMISSION_MISSING
                !hasFix || fixAgeMillis == null -> HeadingAvailability.NO_FIX
                fixAgeMillis > maxFixAgeMillis -> HeadingAvailability.FIX_STALE
                bearingDeg == null || !bearingDeg.isFinite() ->
                    HeadingAvailability.NO_BEARING

                else -> HeadingAvailability.OK
            }
            val reported = availability == HeadingAvailability.OK
            return VehicleHeading(
                timestampMillis = timestampMillis,
                availability = availability,
                bearingDeg = if (reported) normalizeDegrees(bearingDeg!!) else null,
                // The accuracy and the speed describe the fix, not the course,
                // so they stay readable when the course does not. A reader that
                // holds the last heading uses the speed to decide whether that
                // hold is still believable.
                bearingAccuracyDeg = bearingAccuracyDeg?.takeIf { it.isFinite() && it >= 0.0 },
                speedMps = speedMps?.takeIf { it.isFinite() && it >= 0.0 },
                fixAgeMillis = fixAgeMillis,
            )
        }

        /** Folds any angle into 0 degrees up to, but not including, 360. */
        fun normalizeDegrees(value: Double): Double {
            val wrapped = value % 360.0
            return if (wrapped < 0.0) wrapped + 360.0 else wrapped
        }
    }
}
