package com.timhss.capyenergy.projection

/**
 * Every rule that decides whether a touch may be sent, and in what shape.
 *
 * Pure: no Android types, no binder, no threading. One instance per
 * [ProjectionStack], because the gesture state is per stack. The controller
 * owns the instance and calls it under its own lock.
 *
 * It does **not** map coordinates. The caller maps View space into buffer space
 * (§4.2 of the touch doc) because only the caller knows the widget's box fit.
 * What this class guarantees is that whatever arrives leaves inside the buffer:
 * the CarPlay wire packs X and Y as 16-bit little-endian, so a negative value
 * would reach the phone as a number near 65535.
 */
class ProjectionTouchPolicy(private val stack: ProjectionStack) {

    private var bufferWidth = 0
    private var bufferHeight = 0

    /**
     * The correction for this stack's own mismatch. Identity until a reader
     * calibrates one — see [ProjectionTouchCalibration] for why it cannot be
     * derived instead.
     */
    var calibration: ProjectionTouchCalibration = ProjectionTouchCalibration.identity

    /** Ids with a finger currently down, in the order they went down. */
    private val livePointers = mutableListOf<Int>()

    /**
     * The geometry the caller mapped into, which is the geometry the OEM
     * divides by. It must be the same number that was passed to
     * `notifyMainSurfaceAttached`; two different values put the touch and the
     * picture in different places.
     */
    fun setBufferSize(width: Int, height: Int) {
        bufferWidth = if (width > 0) width else 0
        bufferHeight = if (height > 0) height else 0
        if (bufferWidth == 0 || bufferHeight == 0) livePointers.clear()
    }

    val hasLivePointers: Boolean get() = livePointers.isNotEmpty()

    /** Forgets the gesture without sending anything. */
    fun reset() = livePointers.clear()

    /**
     * The lift to send before the surface goes away.
     *
     * A gesture that is abandoned mid-press — the card closes, the binding
     * drops — leaves the phone holding a finger that never comes up. Returns
     * null when nothing is down.
     */
    fun releaseGesture(): ProjectionTouchDecision.Send? {
        if (livePointers.isEmpty()) return null
        val id = livePointers.first()
        livePointers.clear()
        return ProjectionTouchDecision.Send(
            action = ProjectionTouchAction.UP,
            actionIndex = 0,
            pointers = listOf(ProjectionTouchPointer(id, 0.0, 0.0)),
        )
    }

    fun decide(request: ProjectionTouchRequest): ProjectionTouchDecision {
        if (bufferWidth <= 0 || bufferHeight <= 0) {
            return ProjectionTouchDecision.Drop(ProjectionTouchDrop.BUFFER_UNKNOWN)
        }
        if (request.pointers.isEmpty()) {
            return ProjectionTouchDecision.Drop(ProjectionTouchDrop.NO_POINTERS)
        }
        if (request.pointers.any { !it.x.isFinite() || !it.y.isFinite() }) {
            return ProjectionTouchDecision.Drop(ProjectionTouchDrop.COORD_NOT_FINITE)
        }

        // CANCEL never goes on the wire. The OEM CarPlay path drops every action
        // >= 3 in silence, so a forwarded cancel is a press that never ends.
        val action = if (request.action == ProjectionTouchAction.CANCEL) {
            ProjectionTouchAction.UP
        } else {
            request.action
        }

        return if (stack.supportsMultiTouch) {
            decideMulti(action, request)
        } else {
            decideSingle(action, request)
        }
    }

    // --- Single touch (CarPlay) ---

    private fun decideSingle(
        action: Int,
        request: ProjectionTouchRequest,
    ): ProjectionTouchDecision {
        when (action) {
            ProjectionTouchAction.POINTER_DOWN, ProjectionTouchAction.POINTER_UP ->
                return ProjectionTouchDecision.Drop(ProjectionTouchDrop.SECOND_POINTER)
            ProjectionTouchAction.DOWN,
            ProjectionTouchAction.UP,
            ProjectionTouchAction.MOVE,
            -> Unit
            else -> return ProjectionTouchDecision.Drop(ProjectionTouchDrop.ACTION_UNSUPPORTED)
        }
        if (request.pointers.size > 1) {
            return ProjectionTouchDecision.Drop(ProjectionTouchDrop.SECOND_POINTER)
        }
        val pointer = request.pointers.first()
        val live = livePointers.firstOrNull()

        if (action == ProjectionTouchAction.DOWN) {
            if (live != null && live != pointer.id) {
                return ProjectionTouchDecision.Drop(ProjectionTouchDrop.SECOND_POINTER)
            }
            livePointers.clear()
            livePointers.add(pointer.id)
        } else {
            if (live != pointer.id) {
                return ProjectionTouchDecision.Drop(ProjectionTouchDrop.UNKNOWN_POINTER)
            }
            if (action == ProjectionTouchAction.UP) livePointers.clear()
        }

        return ProjectionTouchDecision.Send(
            action = action,
            actionIndex = 0,
            pointers = listOf(clamp(pointer)),
        )
    }

    // --- Multi touch (Android Auto) ---

    private fun decideMulti(
        action: Int,
        request: ProjectionTouchRequest,
    ): ProjectionTouchDecision {
        when (action) {
            ProjectionTouchAction.DOWN,
            ProjectionTouchAction.UP,
            ProjectionTouchAction.MOVE,
            ProjectionTouchAction.POINTER_DOWN,
            ProjectionTouchAction.POINTER_UP,
            -> Unit
            else -> return ProjectionTouchDecision.Drop(ProjectionTouchDrop.ACTION_UNSUPPORTED)
        }

        val indexed = action == ProjectionTouchAction.POINTER_DOWN ||
            action == ProjectionTouchAction.POINTER_UP
        if (indexed && request.actionIndex !in request.pointers.indices) {
            return ProjectionTouchDecision.Drop(ProjectionTouchDrop.UNKNOWN_POINTER)
        }

        when (action) {
            ProjectionTouchAction.DOWN -> {
                livePointers.clear()
                livePointers.add(request.pointers.first().id)
            }
            ProjectionTouchAction.POINTER_DOWN -> {
                if (livePointers.isEmpty()) {
                    return ProjectionTouchDecision.Drop(ProjectionTouchDrop.UNKNOWN_POINTER)
                }
                val id = request.pointers[request.actionIndex].id
                if (!livePointers.contains(id)) livePointers.add(id)
            }
            ProjectionTouchAction.POINTER_UP -> {
                val id = request.pointers[request.actionIndex].id
                if (!livePointers.remove(id)) {
                    return ProjectionTouchDecision.Drop(ProjectionTouchDrop.UNKNOWN_POINTER)
                }
            }
            ProjectionTouchAction.MOVE -> {
                if (livePointers.isEmpty()) {
                    return ProjectionTouchDecision.Drop(ProjectionTouchDrop.UNKNOWN_POINTER)
                }
            }
            ProjectionTouchAction.UP -> {
                if (livePointers.isEmpty()) {
                    return ProjectionTouchDecision.Drop(ProjectionTouchDrop.UNKNOWN_POINTER)
                }
                livePointers.clear()
            }
        }

        return ProjectionTouchDecision.Send(
            action = action,
            actionIndex = request.actionIndex,
            pointers = request.pointers.map { clamp(it) },
        )
    }

    /**
     * Correct, then clamp — and in that order.
     *
     * The correction is allowed to push a point past the edge; the clamp is
     * what decides that a touch on the last row still lands on the last row
     * rather than wrapping. Clamping first would throw away the very range the
     * correction needs to work in.
     */
    private fun clamp(pointer: ProjectionTouchPointer): ProjectionTouchPointer {
        val corrected = calibration.apply(pointer, bufferWidth, bufferHeight)
        return ProjectionTouchPointer(
            id = corrected.id,
            x = corrected.x.coerceIn(0.0, bufferWidth.toDouble()),
            y = corrected.y.coerceIn(0.0, bufferHeight.toDouble()),
        )
    }
}
