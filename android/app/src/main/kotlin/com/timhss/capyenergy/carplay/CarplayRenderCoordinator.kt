package com.timhss.capyenergy.carplay

/**
 * Drives [CarplayRenderGateway] from lifecycle inputs.
 *
 * Every rule that can break the OEM CarPlay app lives here, and this class has
 * no Android dependencies so all of it is covered by JVM unit tests. Callers
 * push inputs; the coordinator decides. Do not let a caller call the gateway
 * directly.
 *
 * Not thread-safe on its own. [CarplaySurfaceHost] serialises access.
 */
class CarplayRenderCoordinator(
    private val gateway: CarplayRenderGateway,
    private val onChanged: () -> Unit = {},
) {
    var inputs: CarplayInputs = CarplayInputs()
        private set

    /** True while we own the OEM renderer's main surface. */
    var attached: Boolean = false
        private set

    var lastError: String? = null
        private set

    /** Diagnostics only — surfaced in the status map, never used for decisions. */
    var attachCount: Int = 0
        private set

    fun setDartActive(value: Boolean) = update { it.copy(dartActive = value) }

    fun setActivityResumed(value: Boolean) = update { it.copy(activityResumed = value) }

    fun setServiceConnected(value: Boolean) = update { it.copy(serviceConnected = value) }

    fun setSurfaceReady(value: Boolean) = update { it.copy(surfaceReady = value) }

    fun setBufferSize(width: Int, height: Int) =
        update { it.copy(bufferWidth = width, bufferHeight = height) }

    /** R3. Same-surface re-attach: repairs a torn-down EGL, no-op when healthy. */
    fun refresh() = reconcile(refreshRequested = true)

    private inline fun update(transform: (CarplayInputs) -> CarplayInputs) {
        val next = transform(inputs)
        if (next == inputs) return
        inputs = next
        reconcile(refreshRequested = false)
    }

    private fun reconcile(refreshRequested: Boolean) {
        when (CarplayAttachPolicy.decide(inputs, attached, refreshRequested)) {
            CarplayAction.NONE -> return

            CarplayAction.TAKE_OVER -> {
                // R2: detach first, same thread, always. Attaching a different
                // Surface on top leaves the video on the old target and
                // corrupts that host's glViewport with our dimensions (§10.2).
                gateway.detach()
                applyAttach(isTakeOver = true)
            }

            CarplayAction.REFRESH -> {
                // R3: attach only. A detach here would be a full EGL teardown
                // and rebuild — the exact cost this path exists to avoid.
                applyAttach(isTakeOver = false)
            }

            CarplayAction.RELEASE -> {
                val ok = gateway.detach()
                // Drop ownership regardless: if the remote is gone we are not
                // the host any more either way, and staying "attached" would
                // block the next takeover.
                attached = false
                lastError = if (ok) null else "DETACH_FAILED"
                onChanged()
            }
        }
    }

    private fun applyAttach(isTakeOver: Boolean) {
        val ok = gateway.attach(inputs.bufferWidth, inputs.bufferHeight)
        if (ok) {
            attached = true
            // Only ownership transitions are counted. R3 refreshes (watchdog,
            // heartbeat, manual Reconnect) re-attach the same Surface many
            // times per takeover, and counting those would make the number
            // climb on its own — which is exactly what validation.md T5/T6
            // read to tell a healthy takeover from a repeating one.
            if (isTakeOver) attachCount += 1
            lastError = null
        } else {
            // Leave `attached` false so the next reconcile retries a takeover
            // instead of assuming we own a surface we do not.
            attached = false
            lastError = "ATTACH_FAILED"
        }
        onChanged()
    }
}
