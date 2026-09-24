package com.timhss.capyenergy.projection

/**
 * What this app knows about the two projection stacks, at one moment.
 *
 * P3. Nothing here describes rendering. `attached`, `canRender` and the buffer
 * size live on `CarplayStatus` and describe this app's own surface; a black
 * card with a live attach and a black card with no phone look identical, which
 * is exactly why presence must come from its own source. The two are separate
 * channels with separate maps so that neither can be mistaken for the other.
 *
 * The edge timestamps are `SystemClock.elapsedRealtime` and exist only to order
 * two connect edges against each other. They are not wall-clock time and must
 * not be shown.
 */
data class ProjectionPresenceSnapshot(
    val carplay: PresenceState,
    val androidAuto: PresenceState,
    /** The OEM app declares the service this head unit was asked about. */
    val carplayAvailable: Boolean,
    val androidAutoAvailable: Boolean,
    val carplayEdgeAt: Long?,
    val androidAutoEdgeAt: Long?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "carplay" to carplay.wireName(),
        "androidAuto" to androidAuto.wireName(),
        "carplayAvailable" to carplayAvailable,
        "androidAutoAvailable" to androidAutoAvailable,
        "carplayEdgeAt" to carplayEdgeAt,
        "androidAutoEdgeAt" to androidAutoEdgeAt,
    )

    companion object {
        val unknown = ProjectionPresenceSnapshot(
            carplay = PresenceState.UNKNOWN,
            androidAuto = PresenceState.UNKNOWN,
            carplayAvailable = false,
            androidAutoAvailable = false,
            carplayEdgeAt = null,
            androidAutoEdgeAt = null,
        )
    }
}
