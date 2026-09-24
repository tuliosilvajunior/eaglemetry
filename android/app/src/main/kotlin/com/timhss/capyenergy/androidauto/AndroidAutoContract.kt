package com.timhss.capyenergy.androidauto

/** The OEM Android Auto renderer contract (package, action, transaction codes). */
object AndroidAutoContract {
    const val PACKAGE = "com.njda.aauto"
    const val EXFEATURE_ACTION = "aauto.exfeature.service"

    /** Fallback buffer geometry when the display cannot be measured. */
    const val DEFAULT_BUFFER_WIDTH = 1920
    const val DEFAULT_BUFFER_HEIGHT = 1080

    /**
     * Same-surface re-attach delays after a takeover, in ms.
     *
     * R3. The OEM `AutoActivity`'s surface teardown is asynchronous, so it can
     * clear the render thread a moment *after* we attached. Re-attaching the
     * same Surface rebuilds it and is a no-op when nothing broke: `q.i()`
     * recalculates the view area and posts a frame, and `h2.d.c()` starts a
     * render thread only when the thread field is null.
     */
    val REFRESH_DELAYS_MS = longArrayOf(600L, 1_800L)

    /**
     * Slow self-heal while attached, in ms. 0 disables it.
     *
     * **Off, and this is the difference from CarPlay.** On this stack an attach
     * is not only a graphics operation: `q.i()` ends with
     * `c2.d.b().m(true, (byte) 0, true)`, a Carlink message that tells the
     * phone side the projection surface is live. A repeating bare re-attach
     * would repeat that message for as long as the card is open, at an interval
     * nobody has measured. The two bounded takeover-time refreshes above close
     * the teardown race on their own. Raise this only after hardware step T11
     * shows it is needed and that the repeated message is harmless.
     */
    const val HEARTBEAT_MS = 0L
}

/** Everything the attach decision depends on. No Android types — keep it that way. */
data class AndroidAutoInputs(
    val dartActive: Boolean = false,
    val activityResumed: Boolean = false,
    val serviceConnected: Boolean = false,
    val surfaceReady: Boolean = false,
    val bufferWidth: Int = 0,
    val bufferHeight: Int = 0,
)

enum class AndroidAutoAction {
    NONE,

    /** R2: `detach()` then `attach()`. The only way to become the host. */
    TAKE_OVER,

    /** R3: `attach()` alone, same Surface. Never preceded by a detach. */
    REFRESH,

    /** R4: `detach()` alone. Hands the renderer back to the OEM. */
    RELEASE,
}
