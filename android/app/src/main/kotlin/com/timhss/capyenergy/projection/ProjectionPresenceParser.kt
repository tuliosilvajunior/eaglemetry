package com.timhss.capyenergy.projection

/**
 * The two pure decisions in this feature: what a broadcast means, and what a
 * binder reply means.
 *
 * No Android imports, on purpose. This is the part that can be wrong in a way
 * nobody sees until a car is in front of them, so it is the part the JVM tests
 * can drive directly.
 */
object ProjectionPresenceParser {

    /** Which protocol an action belongs to, or null when it is neither. */
    fun protocolOf(action: String?): Protocol? = when (action) {
        ProjectionContract.CARPLAY_BROADCAST -> Protocol.CARPLAY
        ProjectionContract.ANDROID_AUTO_BROADCAST -> Protocol.ANDROID_AUTO
        else -> null
    }

    /**
     * The state a broadcast reports, or null to leave the state unchanged.
     *
     * Both apps send many other `notification` values on the same action —
     * `poweron_request`, `alert_active`, `media_active` and more. Only the two
     * connection edges are answers to this question; every other value must
     * leave the state exactly as it was, including [PresenceState.UNKNOWN].
     * A missing extra is one of those cases, not a disconnection.
     */
    fun stateFromNotification(notification: String?): PresenceState? = when (notification) {
        ProjectionContract.NOTIFICATION_CONNECTED -> PresenceState.CONNECTED
        ProjectionContract.NOTIFICATION_DISCONNECTED -> PresenceState.DISCONNECTED
        else -> null
    }

    /**
     * The state a getter reply reports.
     *
     * Both reads answer one int, and both use it the same way: CarPlay writes
     * `isConnected()` as 0 or 1, and Android Auto writes 1 before the current
     * device or 0 when there is none. So a non-zero int is a connected phone in
     * both cases.
     *
     * A null reply is a read that did not happen — a failed bind, a dead remote,
     * a service this head unit does not have. That is [PresenceState.UNKNOWN],
     * never [PresenceState.DISCONNECTED].
     */
    fun stateFromReply(reply: Int?): PresenceState = when {
        reply == null -> PresenceState.UNKNOWN
        reply != 0 -> PresenceState.CONNECTED
        else -> PresenceState.DISCONNECTED
    }

    enum class Protocol { CARPLAY, ANDROID_AUTO }
}
