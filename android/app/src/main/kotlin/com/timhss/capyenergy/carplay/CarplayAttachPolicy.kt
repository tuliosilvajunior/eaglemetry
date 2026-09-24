package com.timhss.capyenergy.carplay

object CarplayAttachPolicy {

    /**
     * R1 + R7. All five must hold before a single pixel is worth asking for.
     * Zero dimensions are rejected here because `p.f()` silently keeps the
     * previous value (§4.1) and the render loop then bails out with
     * "Missing content area" (§4.3) — a black screen with no error anywhere.
     */
    fun shouldRender(inputs: CarplayInputs): Boolean =
        inputs.dartActive &&
            inputs.activityResumed &&
            inputs.serviceConnected &&
            inputs.surfaceReady &&
            inputs.bufferWidth > 0 &&
            inputs.bufferHeight > 0

    fun decide(
        inputs: CarplayInputs,
        attached: Boolean,
        refreshRequested: Boolean,
    ): CarplayAction {
        val render = shouldRender(inputs)
        return when {
            render && !attached -> CarplayAction.TAKE_OVER
            render && refreshRequested -> CarplayAction.REFRESH
            !render && attached -> CarplayAction.RELEASE
            else -> CarplayAction.NONE
        }
    }
}
