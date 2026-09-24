package com.timhss.capyenergy.androidauto

/**
 * The two transactions that move pixels. Narrow on purpose: it is the seam the
 * JVM tests fake, and it keeps `android.view.Surface` out of the state machine.
 *
 * Implementations must swallow every remote failure and report it as `false`
 * (R9) — a dead Android Auto process must never surface as an exception in the
 * activity lifecycle.
 */
interface AndroidAutoRenderGateway {

    /** Transaction 3, `notifyMainSurfaceAttached(surface, width, height)`. */
    fun attach(width: Int, height: Int): Boolean

    /** Transaction 4, `notifyMainSurfaceDetached()`. */
    fun detach(): Boolean
}
