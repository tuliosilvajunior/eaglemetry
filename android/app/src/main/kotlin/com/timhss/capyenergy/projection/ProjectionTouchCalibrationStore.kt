package com.timhss.capyenergy.projection

import android.content.Context

/**
 * Where a calibration survives a restart.
 *
 * It is kept native, beside the code that applies it, rather than pushed down
 * from Dart on every start. A correction that only exists once the UI has
 * mounted would leave the first touches of every boot uncorrected, and the
 * reader would have no way to tell that from a calibration that did not save.
 *
 * Its own preferences file: the projection package owes nothing to
 * `TelemetrySettings`, and a wipe of one must not take the other with it.
 */
class ProjectionTouchCalibrationStore(context: Context) {
    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun read(stack: ProjectionStack): ProjectionTouchCalibration {
        val name = stack.wireName
        // The measured default stands in per field, not per record. A file
        // that holds three of the four keys is a partial write, and falling
        // back to 1.0 or 0.0 there would put a value on the axis that nobody
        // ever measured.
        val fallback = ProjectionTouchCalibration.defaultFor(stack)
        // Stored as floats and re-gated through `of` on the way out: a
        // preferences file is editable, and a value that was valid when it was
        // written is not proof that it is valid now.
        return ProjectionTouchCalibration.of(
            scaleX = prefs.getFloat("$name.$KEY_SCALE_X", fallback.scaleX.toFloat()).toDouble(),
            offsetX = prefs.getFloat("$name.$KEY_OFFSET_X", fallback.offsetX.toFloat()).toDouble(),
            scaleY = prefs.getFloat("$name.$KEY_SCALE_Y", fallback.scaleY.toFloat()).toDouble(),
            offsetY = prefs.getFloat("$name.$KEY_OFFSET_Y", fallback.offsetY.toFloat()).toDouble(),
        )
    }

    fun write(stack: ProjectionStack, calibration: ProjectionTouchCalibration) {
        val name = stack.wireName
        prefs.edit()
            .putFloat("$name.$KEY_SCALE_X", calibration.scaleX.toFloat())
            .putFloat("$name.$KEY_OFFSET_X", calibration.offsetX.toFloat())
            .putFloat("$name.$KEY_SCALE_Y", calibration.scaleY.toFloat())
            .putFloat("$name.$KEY_OFFSET_Y", calibration.offsetY.toFloat())
            .apply()
    }

    companion object {
        const val PREFS_NAME = "projection_touch"
        private const val KEY_SCALE_X = "scaleX"
        private const val KEY_OFFSET_X = "offsetX"
        private const val KEY_SCALE_Y = "scaleY"
        private const val KEY_OFFSET_Y = "offsetY"
    }
}
