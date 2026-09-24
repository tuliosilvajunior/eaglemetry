package com.timhss.capyenergy.androidauto

object AndroidAutoAttachPolicy {

    /**
     * R1 + R7. All five must hold before a single pixel is worth asking for.
     * Zero dimensions are rejected here because `q.f()` (`t1/q.java:246`)
     * returns at once when either is zero, so the renderer keeps its previous
     * view area — a black card with no error reported anywhere.
     */
    fun shouldRender(inputs: AndroidAutoInputs): Boolean =
        inputs.dartActive &&
            inputs.activityResumed &&
            inputs.serviceConnected &&
            inputs.surfaceReady &&
            inputs.bufferWidth > 0 &&
            inputs.bufferHeight > 0

    fun decide(
        inputs: AndroidAutoInputs,
        attached: Boolean,
        refreshRequested: Boolean,
    ): AndroidAutoAction {
        val render = shouldRender(inputs)
        return when {
            render && !attached -> AndroidAutoAction.TAKE_OVER
            render && refreshRequested -> AndroidAutoAction.REFRESH
            !render && attached -> AndroidAutoAction.RELEASE
            else -> AndroidAutoAction.NONE
        }
    }
}
