package com.timhss.capyenergy.projection

/**
 * What the two OEM projection apps expose, and the exact reads this app makes.
 *
 * Every constant here was read from the decompiled OEM APKsNothing here is confirmed on a
 * running head unit yet.
 */
object ProjectionContract {

    const val CARPLAY_PACKAGE = "com.njda.carplay"
    const val ANDROID_AUTO_PACKAGE = "com.njda.aauto"

    /** `carplay.session.service`, which answers `isConnected()`. */
    const val CARPLAY_SESSION_ACTION = "carplay.session.service"

    /** `aauto.devicelist.service`, which answers `getCurrentDevice()`. */
    const val ANDROID_AUTO_DEVICELIST_ACTION = "aauto.devicelist.service"

    /**
     * Binder interface descriptors. `Parcel.writeInterfaceToken` must send
     * exactly these, because the remote `onTransact` calls
     * `enforceInterface` before it looks at the transaction code.
     */
    const val CARPLAY_SESSION_DESCRIPTOR = "com.njda.carplay.session.ISessionManager"
    const val ANDROID_AUTO_DEVICELIST_DESCRIPTOR =
        "com.njda.aauto.connect.devicelist.IAutoDeviceManager"

    /**
     * `ISessionManager.isConnected()`. The stub answers it inline from the
     * field the OEM log calls `isCarplayConnected`, and writes one int.
     */
    const val TX_CARPLAY_IS_CONNECTED = 48

    /**
     * `IAutoDeviceManager.getCurrentDevice()`. The reply is `writeInt(1)`
     * followed by a custom parcelable, or `writeInt(0)` alone. This app reads
     * the int and stops there — see [ProjectionPresenceProbe].
     */
    const val TX_ANDROID_AUTO_CURRENT_DEVICE = 7

    /** Connection edges. Sent with no permission and no target package. */
    const val CARPLAY_BROADCAST = "com.njda.carplay.broadcast"
    const val ANDROID_AUTO_BROADCAST = "com.njda.aauto.broadcast"

    /** The extra both apps carry the edge in. */
    const val EXTRA_NOTIFICATION = "notification"

    const val NOTIFICATION_CONNECTED = "connected"
    const val NOTIFICATION_DISCONNECTED = "disconnected"
}

/**
 * Whether one protocol has a live phone session.
 *
 * [UNKNOWN] is not [DISCONNECTED]. It means no getter answered and no edge has
 * arrived — the OEM app is absent from this head unit, or a binder call failed.
 * The app must not say "no phone connected" when it means "this app does not
 * know", so the two states stay apart all the way to the UI.
 */
enum class PresenceState {
    CONNECTED,
    DISCONNECTED,
    UNKNOWN,
    ;

    fun wireName(): String = name.lowercase()
}
