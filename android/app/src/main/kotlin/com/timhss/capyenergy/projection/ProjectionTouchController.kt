package com.timhss.capyenergy.projection

import android.content.Context
import android.os.Handler
import android.os.HandlerThread

/**
 * Android glue for touch forwarding: one host thread, two bindings, two policies.
 *
 * It owns no rule. [ProjectionTouchPolicy] says what may be sent and
 * [ProjectionTouchSession] sends it; this class only decides where each of the
 * two runs.
 *
 * Threading:
 *  - The **policy** runs on the calling thread under [lock]. It is pure and
 *    fast, and running it there is what lets [send] answer the caller in the
 *    same call instead of making the UI ask again what happened to its touch.
 *  - The **binder call** is posted to `HandlerThread("ProjectionTouch")`.
 *    `notifyMotionEvent` is a synchronous transaction and a MOVE stream runs at
 *    the pointer rate; a blocked platform thread there is a dropped frame in
 *    every other part of the app. A `Handler` keeps the posted sends in order,
 *    which a gesture depends on.
 *  - [ProjectionTouchSession] state belongs to the host thread alone.
 */
class ProjectionTouchController(
    context: Context,
    private val onStatus: (ProjectionTouchStatus) -> Unit,
) {
    private val appContext = context.applicationContext
    private val lock = Any()

    private val hostThread = HandlerThread("ProjectionTouch")
    private val hostHandler: Handler

    private val policies = ProjectionStack.entries.associateWith { ProjectionTouchPolicy(it) }
    private val sessions: Map<ProjectionStack, ProjectionTouchSession>

    private val bufferSizes = ProjectionStack.entries.associateWith { 0 to 0 }.toMutableMap()
    private val sent = ProjectionStack.entries.associateWith { 0 }.toMutableMap()
    private val dropped = ProjectionStack.entries.associateWith { 0 }.toMutableMap()
    private val lastDrop = mutableMapOf<ProjectionStack, String?>()

    private val calibrations = ProjectionTouchCalibrationStore(appContext)

    private var disposed = false

    init {
        hostThread.start()
        hostHandler = Handler(hostThread.looper)
        // Touch calibration is hidden, not deleted: the per-stack default stays
        // authoritative and any stored value is ignored, so a stale correction
        // from a prior build or resolution can never take effect.
        for (stack in ProjectionStack.entries) {
            policies.getValue(stack).calibration =
                ProjectionTouchCalibration.defaultFor(stack)
        }
        sessions = ProjectionStack.entries.associateWith { stack ->
            ProjectionTouchSession(
                context = appContext,
                stack = stack,
                post = { block -> hostHandler.post { if (!disposed) block() } },
                onChanged = { publish() },
            )
        }
    }

    // --- Binding ---

    /**
     * Binds the session service. Safe before anything is on screen: binding
     * takes no renderer and sends no touch, so it carries none of the attach
     * path's exposure. It is what makes `bound` a real signal instead of a flag
     * that only turns true once a touch has already been lost.
     */
    fun bind(stack: ProjectionStack) {
        hostHandler.post {
            if (disposed) return@post
            sessions.getValue(stack).bind()
            publish()
        }
    }

    /**
     * Drops the binding, after lifting any finger that is still down.
     *
     * The lift is not politeness. The phone holds the press until an UP
     * arrives, and a binding that goes away mid-gesture never sends one.
     */
    fun unbind(stack: ProjectionStack) {
        val release = synchronized(lock) { policies.getValue(stack).releaseGesture() }
        hostHandler.post {
            if (disposed) return@post
            val session = sessions.getValue(stack)
            if (release != null) session.send(release)
            session.unbind()
            publish()
        }
    }

    /**
     * The geometry the caller maps into, which must be the geometry that was
     * passed to `notifyMainSurfaceAttached`. Until it is known, every touch is
     * refused: with no buffer there is nothing to clamp against, and the OEM
     * CarPlay path divides by that width — a zero there throws inside its own
     * `onTransact`.
     */
    fun setBufferSize(stack: ProjectionStack, width: Int, height: Int) {
        synchronized(lock) {
            policies.getValue(stack).setBufferSize(width, height)
            bufferSizes[stack] = (if (width > 0) width else 0) to (if (height > 0) height else 0)
        }
        publish()
    }

    /**
     * Sets the correction for one stack and saves it.
     *
     * It takes effect on the next touch, not on the one in flight: a gesture
     * that started under one correction finishes under it, or the DOWN and the
     * UP would name two different places.
     */
    fun setCalibration(stack: ProjectionStack, calibration: ProjectionTouchCalibration) {
        synchronized(lock) {
            policies.getValue(stack).calibration = calibration
        }
        calibrations.write(stack, calibration)
        publish()
    }

    /**
     * Applies the rules and, when they allow it, queues the binder call.
     *
     * Returns null when the touch was accepted, or the drop code when it was
     * not. A queued send can still fail later at the binder; that shows up in
     * the status, not in this return, because by then the caller has moved on.
     */
    fun send(request: ProjectionTouchRequest): String? {
        val decision = synchronized(lock) {
            if (disposed) return ProjectionTouchDrop.NOT_BOUND
            policies.getValue(request.stack).decide(request)
        }
        when (decision) {
            is ProjectionTouchDecision.Drop -> {
                countDrop(request.stack, decision.reason)
                publish()
                return decision.reason
            }

            is ProjectionTouchDecision.Send -> {
                hostHandler.post {
                    if (disposed) return@post
                    val failure = sessions.getValue(request.stack).send(decision)
                    if (failure == null) {
                        synchronized(lock) { sent[request.stack] = sent.getValue(request.stack) + 1 }
                    } else {
                        // The remote is gone mid-gesture. Forget the finger, or
                        // the next DOWN is refused as a second pointer.
                        synchronized(lock) { policies.getValue(request.stack).reset() }
                        countDrop(request.stack, failure)
                    }
                    publish()
                }
                return null
            }
        }
    }

    /**
     * Lifts every finger without unbinding.
     *
     * For `onPause`: the card can go away between a DOWN and its UP, and the
     * pointer stream simply stops. Nothing else ever tells the phone.
     */
    fun releaseGestures() {
        val releases = synchronized(lock) {
            ProjectionStack.entries.mapNotNull { stack ->
                policies.getValue(stack).releaseGesture()?.let { stack to it }
            }
        }
        if (releases.isEmpty()) return
        hostHandler.post {
            if (disposed) return@post
            for ((stack, decision) in releases) sessions.getValue(stack).send(decision)
            publish()
        }
    }

    fun status(): ProjectionTouchStatus = buildStatus()

    fun dispose() {
        synchronized(lock) {
            if (disposed) return
            disposed = true
        }
        // Not posted: the looper is about to quit, so a posted unbind would
        // never run and the service records would leak.
        for (session in sessions.values) runCatching { session.unbind() }
        hostHandler.removeCallbacksAndMessages(null)
        hostThread.quitSafely()
    }

    // --- Status ---

    private fun countDrop(stack: ProjectionStack, reason: String) {
        synchronized(lock) {
            dropped[stack] = dropped.getValue(stack) + 1
            lastDrop[stack] = reason
        }
    }

    private fun buildStatus(): ProjectionTouchStatus = synchronized(lock) {
        ProjectionTouchStatus(
            carplay = statusFor(ProjectionStack.CARPLAY),
            androidAuto = statusFor(ProjectionStack.ANDROID_AUTO),
        )
    }

    private fun statusFor(stack: ProjectionStack): ProjectionTouchStackStatus {
        val session = sessions.getValue(stack)
        val (width, height) = bufferSizes.getValue(stack)
        return ProjectionTouchStackStatus(
            available = session.available,
            bound = session.bound,
            bufferWidth = width,
            bufferHeight = height,
            gestureActive = policies.getValue(stack).hasLivePointers,
            calibration = policies.getValue(stack).calibration,
            sentCount = sent.getValue(stack),
            droppedCount = dropped.getValue(stack),
            lastDropReason = lastDrop[stack],
            lastError = session.lastError,
        )
    }

    /**
     * Publishes only when something a reader can act on changed.
     *
     * The counters are deliberately not part of that test. A MOVE stream runs
     * at the pointer rate, so publishing on every send would put an event on
     * the channel per touch sample and make the counters the reason nobody can
     * afford to watch the status at all. They still ride along in whatever gets
     * published, so they stay current whenever anything else moves.
     */
    private fun publish() {
        val status = buildStatus()
        val key = listOf(
            status.carplay.available, status.carplay.bound,
            status.carplay.bufferWidth, status.carplay.bufferHeight,
            status.carplay.gestureActive, status.carplay.lastDropReason,
            status.carplay.lastError, status.carplay.calibration,
            status.androidAuto.available, status.androidAuto.bound,
            status.androidAuto.bufferWidth, status.androidAuto.bufferHeight,
            status.androidAuto.gestureActive, status.androidAuto.lastDropReason,
            status.androidAuto.lastError, status.androidAuto.calibration,
        )
        synchronized(lock) {
            if (key == lastPublishedKey) return
            lastPublishedKey = key
        }
        onStatus(status)
    }

    private var lastPublishedKey: List<Any?>? = null
}
