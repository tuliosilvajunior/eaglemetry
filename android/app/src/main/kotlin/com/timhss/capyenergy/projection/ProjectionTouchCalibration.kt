package com.timhss.capyenergy.projection

/**
 * A per-axis scale and offset applied to a touch before it leaves, in buffer
 * pixels.
 *
 * ## Why this exists
 *
 * Android Auto does not re-scale a touch the way CarPlay does, and its own two
 * halves disagree. `t1.q.f()` draws the picture at
 * `glViewport(max(marginL, shadowLeft), max(shadowBottom, marginT), …)` while
 * `t1.q.a()` forwards `(x − marginL) / factor`. Four separate things can pull
 * them apart:
 *
 *  - the viewport origin takes the **larger** of the centring margin and the
 *    shadow, and the touch path subtracts only the margin;
 *  - the drawn width is clamped by `shadowRight`, and the touch path divides by
 *    `factor` regardless;
 *  - `notifyVideoConfiguration` crops the source texture to
 *    `(widthMarginLeft … widthPixel − widthMarginRight)`, and the touch path
 *    works in the uncropped `widthPixel` space;
 *  - the viewport's Y is an OpenGL bottom-left origin; the margin it is
 *    compared against is measured from the top.
 *
 * None of the four is readable from this process: the AA exfeature interface
 * exposes surface attach/detach and two listeners, and nothing else. The values
 * only appear in the OEM's own log.
 *
 * ## Why an affine correction is enough
 *
 * Every one of those four is a scale, an offset, or both — on one axis at a
 * time. None of them rotates, shears or bends. So a per-axis
 * `x' = (x − centre) · scale + centre + offset` can absorb whichever one is
 * biting without this side having to know which.
 *
 * Scale is taken **about the centre of the buffer** on purpose. It makes the
 * two knobs independent: correcting the offset does not change the scale, and
 * correcting the scale does not move the point the reader has already lined up.
 * A scale about the origin would move both at once, and a calibration that
 * fights itself does not converge.
 *
 * The default is what was measured on this head unit, per stack — see
 * [defaultFor]. This app does not invent a correction for a car it has not
 * measured.
 */
data class ProjectionTouchCalibration(
    val scaleX: Double = 1.0,
    val offsetX: Double = 0.0,
    val scaleY: Double = 1.0,
    val offsetY: Double = 0.0,
) {
    val isIdentity: Boolean
        get() = scaleX == 1.0 && offsetX == 0.0 && scaleY == 1.0 && offsetY == 0.0

    /**
     * Buffer pixels in, buffer pixels out. The caller clamps afterwards: a
     * correction is allowed to push a point outside the buffer, and it is the
     * clamp — not this — that decides what leaves.
     */
    fun apply(
        pointer: ProjectionTouchPointer,
        bufferWidth: Int,
        bufferHeight: Int,
    ): ProjectionTouchPointer {
        if (isIdentity) return pointer
        val centreX = bufferWidth / 2.0
        val centreY = bufferHeight / 2.0
        return ProjectionTouchPointer(
            id = pointer.id,
            x = (pointer.x - centreX) * scaleX + centreX + offsetX,
            y = (pointer.y - centreY) * scaleY + centreY + offsetY,
        )
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "scaleX" to scaleX,
        "offsetX" to offsetX,
        "scaleY" to scaleY,
        "offsetY" to offsetY,
    )

    companion object {
        val identity = ProjectionTouchCalibration()

        /**
         * Measured on the car, 2026-08-13: Android Auto lands one keyboard row
         * low, at every card size, and horizontally within a key. So it starts
         * shifted up by [ANDROID_AUTO_OFFSET_Y] buffer pixels; CarPlay lands
         * correctly and starts at the identity.
         *
         * This is a starting point, not a constant of the stack. The reader can
         * still tune it, and a saved value overrides it.
         */
        fun defaultFor(stack: ProjectionStack): ProjectionTouchCalibration =
            when (stack) {
                ProjectionStack.CARPLAY -> identity
                ProjectionStack.ANDROID_AUTO ->
                    ProjectionTouchCalibration(offsetY = ANDROID_AUTO_OFFSET_Y)
            }

        const val ANDROID_AUTO_OFFSET_Y = -80.0

        /**
         * Half to double. Wider than any mismatch the OEM code above can
         * produce, and narrow enough that a mis-typed value cannot make the
         * screen unusable in a way the reader cannot see and undo.
         */
        const val MIN_SCALE = 0.5
        const val MAX_SCALE = 2.0

        /** In buffer pixels, each way. A keyboard row is about 100. */
        const val OFFSET_LIMIT = 2_000.0

        /**
         * The only way to build one from outside. A value that is not finite
         * is not a correction, and it must never reach the arithmetic — an
         * infinite offset would silently move every touch to the same edge.
         */
        fun of(
            scaleX: Double,
            offsetX: Double,
            scaleY: Double,
            offsetY: Double,
        ) = ProjectionTouchCalibration(
            scaleX = scale(scaleX),
            offsetX = offset(offsetX),
            scaleY = scale(scaleY),
            offsetY = offset(offsetY),
        )

        private fun scale(value: Double) =
            if (value.isFinite()) value.coerceIn(MIN_SCALE, MAX_SCALE) else 1.0

        private fun offset(value: Double) =
            if (value.isFinite()) value.coerceIn(-OFFSET_LIMIT, OFFSET_LIMIT) else 0.0
    }
}
