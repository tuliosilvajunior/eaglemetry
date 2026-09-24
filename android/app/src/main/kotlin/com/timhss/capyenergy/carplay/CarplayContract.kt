package com.timhss.capyenergy.carplay

/** The OEM CarPlay renderer, reverse-engineered in rendering-decompile-findings.md. */
object CarplayContract {
    const val PACKAGE = "com.njda.carplay"
    const val EXFEATURE_ACTION = "carplay.exfeature.service"

    /** Fallback buffer geometry when the display cannot be measured. */
    const val DEFAULT_BUFFER_WIDTH = 1920
    const val DEFAULT_BUFFER_HEIGHT = 1080

    /**
     * Same-surface re-attach delays after a takeover, in ms.
     *
     * R3. The OEM CarplayActivity's `surfaceDestroyed` is asynchronous, so it
     * can tear down the shared EGL state (§10.3) a moment *after* we attached.
     * Re-attaching the same Surface rebuilds it and is a no-op when nothing
     * broke (§5.2).
     */
    val REFRESH_DELAYS_MS = longArrayOf(600L, 1_800L)

    /**
     * Slow self-heal while attached, in ms. Set to 0 to disable.
     *
     * Recovers from any later teardown we do not observe (phone reconnect,
     * OEM stack restart). Cheap: a same-surface attach re-posts two callables
     * to the GL thread and does not touch EGL or the decoder (§5.2). Isolate
     * this with the kill switch during hardware step T11 before trusting it.
     */
    const val HEARTBEAT_MS = 10_000L
}

/** Everything the attach decision depends on. No Android types — keep it that way. */
data class CarplayInputs(
    val dartActive: Boolean = false,
    val activityResumed: Boolean = false,
    val serviceConnected: Boolean = false,
    val surfaceReady: Boolean = false,
    val bufferWidth: Int = 0,
    val bufferHeight: Int = 0,
)

enum class CarplayAction {
    NONE,

    /** R2: `detach()` then `attach()`. The only way to become the host. */
    TAKE_OVER,

    /** R3: `attach()` alone, same Surface. Never preceded by a detach. */
    REFRESH,

    /** R4: `detach()` alone. Hands the renderer back to the OEM. */
    RELEASE,
}
