package com.timhss.capyenergy.projection

/**
 * The OEM touch-forwarding surface, reverse-engineered in
 * `projection-touch-input-and-coordinate-mapping.md`.
 *
 * Neither OEM app injects into the input system. Each exports a *session*
 * service that takes a plain [android.view.MotionEvent] over AIDL and forwards
 * it to the phone. That service is **not** the exfeature service the render
 * path binds (`CarplayContract.EXFEATURE_ACTION`): it is a second binding, on a
 * second action, with a second interface. Keep the two apart — an exfeature
 * binder cannot send a touch, and a session binder cannot attach a Surface.
 */
object ProjectionTouchContract {
    const val CARPLAY_PACKAGE = "com.njda.carplay"
    const val CARPLAY_SESSION_ACTION = "carplay.session.service"

    const val ANDROID_AUTO_PACKAGE = "com.njda.aauto"
    const val ANDROID_AUTO_SESSION_ACTION = "aauto.session.service"
}

/** Which OEM stack a touch is meant for. */
enum class ProjectionStack(val wireName: String) {
    CARPLAY("carplay"),
    ANDROID_AUTO("android_auto"),
    ;

    /**
     * CarPlay is single-touch: the iAP2 vehicle protocol carries one finger and
     * the OEM packs exactly one coordinate pair into its 5-byte frame. Android
     * Auto forwards `pointerCount` and every pointer id.
     */
    val supportsMultiTouch: Boolean get() = this == ANDROID_AUTO

    companion object {
        fun fromWire(name: String?): ProjectionStack? =
            entries.firstOrNull { it.wireName == name }
    }
}

/**
 * The subset of `MotionEvent` actions this path understands.
 *
 * `p.q()` drops anything `>= 3` without a word, so a raw `ACTION_CANCEL` would
 * leave CarPlay holding a finger that never lifts. The controller rewrites
 * CANCEL into UP rather than passing it on; see [ProjectionTouchPolicy].
 */
object ProjectionTouchAction {
    const val DOWN = 0
    const val UP = 1
    const val MOVE = 2
    const val CANCEL = 3
    const val POINTER_DOWN = 5
    const val POINTER_UP = 6
}

/** One finger, already mapped by the caller into buffer space. */
data class ProjectionTouchPointer(
    val id: Int,
    val x: Double,
    val y: Double,
)

/** What the caller asked to send, before any rule has been applied. */
data class ProjectionTouchRequest(
    val stack: ProjectionStack,
    val action: Int,
    /** Which entry of [pointers] the action is about. Only read for 5 and 6. */
    val actionIndex: Int,
    val pointers: List<ProjectionTouchPointer>,
)

/** What the controller must actually put on the wire, or why it must not. */
sealed interface ProjectionTouchDecision {
    /** Coordinates here are final: clamped into the buffer, safe to serialize. */
    data class Send(
        val action: Int,
        val actionIndex: Int,
        val pointers: List<ProjectionTouchPointer>,
    ) : ProjectionTouchDecision

    /** [reason] is a machine-readable code. Dart maps it to copy. */
    data class Drop(val reason: String) : ProjectionTouchDecision
}

/** Every reason a touch is refused. Stable strings — the UI shows them. */
object ProjectionTouchDrop {
    /** The buffer geometry is not known yet, so nothing can be clamped to it. */
    const val BUFFER_UNKNOWN = "BUFFER_UNKNOWN"

    /** A coordinate that is NaN or infinite. It cannot be mapped or clamped. */
    const val COORD_NOT_FINITE = "COORD_NOT_FINITE"

    /** The request carried no pointer at all. */
    const val NO_POINTERS = "NO_POINTERS"

    /** An action this path does not forward. */
    const val ACTION_UNSUPPORTED = "ACTION_UNSUPPORTED"

    /** A second finger, on a stack that carries one. */
    const val SECOND_POINTER = "SECOND_POINTER"

    /** A MOVE or UP for a finger that never went down here. */
    const val UNKNOWN_POINTER = "UNKNOWN_POINTER"

    /** The session service is not bound. */
    const val NOT_BOUND = "NOT_BOUND"

    /** The binder call threw. */
    const val REMOTE_EXCEPTION = "REMOTE_EXCEPTION"
}
