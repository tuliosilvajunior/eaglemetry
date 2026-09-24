package com.timhss.capyenergy.projection

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import com.njda.aauto.session.ISessionManager as IAutoSessionManager
import com.njda.carplay.session.ISessionManager as ICarplaySessionManager

/**
 * The binder half of one stack's touch path: bind the OEM session service, hold
 * the interface, build the [MotionEvent], send it, drop it.
 *
 * One instance per [ProjectionStack]. It decides nothing — [ProjectionTouchPolicy]
 * has already said what may be sent.
 *
 * Threading: every method and every field here belongs to the controller's host
 * thread. `ServiceConnection` callbacks arrive on the main looper, so they do
 * not touch state directly — they hand the work to [post], which is the
 * controller's host handler. The few fields the controller reads for a status
 * snapshot are `@Volatile` for that one purpose.
 *
 * The two stacks answer different AIDL interfaces on different actions, so the
 * remote reference cannot be one field of one type. The `when` below is the
 * whole of that difference; everything above it is shared.
 */
class ProjectionTouchSession(
    private val context: Context,
    val stack: ProjectionStack,
    private val post: (() -> Unit) -> Unit,
    private val onChanged: () -> Unit,
) {
    private val packageName = when (stack) {
        ProjectionStack.CARPLAY -> ProjectionTouchContract.CARPLAY_PACKAGE
        ProjectionStack.ANDROID_AUTO -> ProjectionTouchContract.ANDROID_AUTO_PACKAGE
    }

    private val action = when (stack) {
        ProjectionStack.CARPLAY -> ProjectionTouchContract.CARPLAY_SESSION_ACTION
        ProjectionStack.ANDROID_AUTO -> ProjectionTouchContract.ANDROID_AUTO_SESSION_ACTION
    }

    @Volatile
    private var carplay: ICarplaySessionManager? = null

    @Volatile
    private var auto: IAutoSessionManager? = null

    private var bindingActive = false
    private var downTimeMs = 0L

    @Volatile
    var available: Boolean = serviceAvailable()
        private set

    @Volatile
    var lastError: String? = null
        private set

    val bound: Boolean get() = carplay != null || auto != null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            post {
                when (stack) {
                    ProjectionStack.CARPLAY ->
                        carplay = ICarplaySessionManager.Stub.asInterface(binder)
                    ProjectionStack.ANDROID_AUTO ->
                        auto = IAutoSessionManager.Stub.asInterface(binder)
                }
                lastError = null
                onChanged()
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // Keep the binding: the framework rebinds with BIND_AUTO_CREATE.
            post {
                clearRemote()
                onChanged()
            }
        }

        override fun onBindingDied(name: ComponentName?) {
            post {
                clearRemote()
                lastError = "BINDING_DIED"
                bindingActive = false
                runCatching { context.unbindService(this) }
                bind()
                onChanged()
            }
        }

        override fun onNullBinding(name: ComponentName?) {
            post {
                clearRemote()
                lastError = "NULL_BINDING"
                onChanged()
            }
        }
    }

    fun bind() {
        available = serviceAvailable()
        if (bindingActive || bound) return
        val accepted = runCatching {
            context.bindService(intent(), connection, Context.BIND_AUTO_CREATE)
        }.getOrDefault(false)
        bindingActive = accepted
        if (!accepted) {
            // bindService can leak its registration record when it fails.
            runCatching { context.unbindService(connection) }
            lastError = "BIND_FAILED"
        }
    }

    fun unbind() {
        if (!bindingActive) {
            clearRemote()
            return
        }
        bindingActive = false
        clearRemote()
        runCatching { context.unbindService(connection) }
    }

    /**
     * Returns null on success, or the drop code that says why nothing was sent.
     *
     * `recycle()` in the `finally` is safe: the binder call is synchronous, so
     * the event is already written into the parcel when the `try` ends.
     */
    fun send(decision: ProjectionTouchDecision.Send): String? {
        if (!bound) return ProjectionTouchDrop.NOT_BOUND
        val event = buildEvent(decision) ?: return ProjectionTouchDrop.NO_POINTERS
        return try {
            when (stack) {
                ProjectionStack.CARPLAY -> carplay?.notifyMotionEvent(event)
                ProjectionStack.ANDROID_AUTO -> auto?.notifyMotionEvent(event)
            }
            lastError = null
            null
        } catch (t: Throwable) {
            // A dead remote must not escape into the Flutter engine.
            clearRemote()
            lastError = ProjectionTouchDrop.REMOTE_EXCEPTION
            ProjectionTouchDrop.REMOTE_EXCEPTION
        } finally {
            event.recycle()
        }
    }

    private fun buildEvent(decision: ProjectionTouchDecision.Send): MotionEvent? {
        val count = decision.pointers.size
        if (count == 0) return null
        val now = SystemClock.uptimeMillis()
        if (decision.action == ProjectionTouchAction.DOWN || downTimeMs == 0L) {
            downTimeMs = now
        }
        val properties = Array(count) { i ->
            MotionEvent.PointerProperties().apply {
                id = decision.pointers[i].id
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
        }
        val coords = Array(count) { i ->
            MotionEvent.PointerCoords().apply {
                x = decision.pointers[i].x.toFloat()
                y = decision.pointers[i].y.toFloat()
                pressure = 1f
                size = 1f
            }
        }
        // The index rides in the high bits of the action, which is where
        // `getActionIndex()` reads it. For a single pointer the shift is a
        // no-op, so the CarPlay side still sees a bare 0/1/2 in `getAction()`.
        val encoded = decision.action or
            (decision.actionIndex shl MotionEvent.ACTION_POINTER_INDEX_SHIFT)
        val event = MotionEvent.obtain(
            downTimeMs,
            now,
            encoded,
            count,
            properties,
            coords,
            0,
            0,
            1f,
            1f,
            0,
            0,
            InputDevice.SOURCE_TOUCHSCREEN,
            0,
        )
        if (decision.action == ProjectionTouchAction.UP) downTimeMs = 0L
        return event
    }

    private fun clearRemote() {
        carplay = null
        auto = null
        downTimeMs = 0L
    }

    private fun intent() = Intent(action).setPackage(packageName)

    private fun serviceAvailable(): Boolean =
        context.packageManager.queryIntentServices(intent(), 0).isNotEmpty()
}
