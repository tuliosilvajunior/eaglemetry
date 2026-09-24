package com.timhss.capyenergy.androidauto

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Surface
import android.view.WindowManager
import com.njda.aauto.exfeature.IExFeatureManager
import io.flutter.view.TextureRegistry

/**
 * Android glue: binder, Flutter [SurfaceTexture], threading, watchdog.
 *
 * It owns binding to the OEM Android Auto exfeature service, the texture that
 * Flutter samples, and the R3 self-heal timers, and feeds every input into
 * [AndroidAutoRenderCoordinator]. It never decides anything itself — every safety
 * rule lives in the coordinator.
 *
 * Threading:
 *  - Ordinary work (activate, deactivate, watchdog, service callbacks) runs on
 *    a dedicated `HandlerThread("AndroidAutoHost")` so binder calls that block
 *    (the OEM GL work runs synchronously on the remote side) never block the
 *    platform thread.
 *  - Texture creation/destruction (`TextureRegistry`, `Surface`) is
 *    platform-thread-only, so it runs on the main looper.
 *  - [onActivityPaused] runs **synchronously on the calling (main) thread and
 *    never posts** — R4. A posted detach could land after the OEM AndroidAutoActivity
 *    builds its surface and tear down the shared EGL state it just created.
 *  - All mutable state and every gateway call is guarded by [lock]; the main
 *    thread may block on it briefly during `onPause` (one EGL teardown).
 */
class AndroidAutoSurfaceHost(
    private val context: Context,
    private val textures: TextureRegistry,
    private val onStatus: (AndroidAutoStatus) -> Unit,
) {
    private val lock = Any()

    private val hostThread = HandlerThread("AndroidAutoHost")
    private val hostHandler: Handler
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Re-queried on every [activate]: the OEM Android Auto app can be installed,
     * updated or disabled after our engine was configured, and a value captured
     * once at construction would pin the UI to "unavailable" for the lifetime
     * of the process with no way back.
     */
    private var available: Boolean = serviceAvailable()

    private var service: IExFeatureManager? = null
    private var bindingActive = false
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var bufferWidth = 0
    private var bufferHeight = 0
    private var hostError: String? = null
    private var disposed = false

    private val coordinator: AndroidAutoRenderCoordinator

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            runOnHost {
                service = IExFeatureManager.Stub.asInterface(binder)
                hostError = null
                coordinator.setServiceConnected(true)
                publishStatusLocked()
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // Binder died or service stopped. Keep the binding: the framework
            // rebinds with BIND_AUTO_CREATE.
            runOnHost {
                service = null
                coordinator.setServiceConnected(false)
                publishStatusLocked()
            }
        }

        override fun onBindingDied(name: ComponentName?) {
            runOnHost {
                service = null
                coordinator.setServiceConnected(false)
                hostError = "BINDING_DIED"
                bindingActive = false
                runCatching { context.unbindService(this) }
                bindLocked()
                publishStatusLocked()
            }
        }

        override fun onNullBinding(name: ComponentName?) {
            runOnHost {
                service = null
                hostError = "NULL_BINDING"
                publishStatusLocked()
            }
        }
    }

    private val repairTask = Runnable {
        synchronized(lock) {
            if (disposed || !coordinator.attached) return@Runnable
            coordinator.refresh()
        }
    }

    private val heartbeatTask = object : Runnable {
        override fun run() {
            var rearm = false
            synchronized(lock) {
                if (disposed || !coordinator.attached) return
                coordinator.refresh()
                rearm = true
            }
            if (rearm && AndroidAutoContract.HEARTBEAT_MS > 0) {
                hostHandler.postDelayed(this, AndroidAutoContract.HEARTBEAT_MS)
            }
        }
    }

    init {
        hostThread.start()
        hostHandler = Handler(hostThread.looper)
        coordinator = AndroidAutoRenderCoordinator(
            gateway = BinderRenderGateway(),
            onChanged = { onCoordinatorChanged() },
        )
    }

    // --- Public API ---

    fun activate(width: Int?, height: Int?, onComplete: (AndroidAutoStatus) -> Unit) {
        hostHandler.post {
            val status = synchronized(lock) {
                if (!disposed) {
                    available = serviceAvailable()
                    val (w, h) = resolveGeometry(width, height)
                    if (entry == null || bufferWidth != w || bufferHeight != h) {
                        // R8: the detach happens here, on the host thread,
                        // before the platform thread frees the old buffers.
                        coordinator.setSurfaceReady(false)
                        createTexture(w, h)
                    }
                    bindLocked()
                    coordinator.setDartActive(true)
                    publishStatusLocked()
                }
                buildStatusLocked()
            }
            onComplete(status)
        }
    }

    /**
     * Establishes the binder connection alone — no texture, no `dartActive`, no
     * attach. `bindService` never touches the shared render singleton — only
     * transactions 3 and 4 do — so this carries none of R1's
     * exposure and is safe to call before the Android Auto card is ever on screen.
     * Lets `bound` become a real boot-time signal instead of stuck at `false`
     * forever behind the circular dependency where only [activate] binds, and
     * [activate] is only reachable once something is already visible.
     */
    fun ensureBound(onComplete: (AndroidAutoStatus) -> Unit) {
        hostHandler.post {
            val status = synchronized(lock) {
                if (!disposed) {
                    available = serviceAvailable()
                    bindLocked()
                }
                buildStatusLocked()
            }
            onComplete(status)
        }
    }

    fun deactivate(onComplete: (AndroidAutoStatus) -> Unit) {
        hostHandler.post {
            val status = synchronized(lock) {
                if (!disposed) {
                    coordinator.setDartActive(false)
                    releaseTexture()
                    unbindLocked()
                    publishStatusLocked()
                }
                buildStatusLocked()
            }
            onComplete(status)
        }
    }

    fun requestRefresh(onComplete: (AndroidAutoStatus) -> Unit) {
        hostHandler.post {
            val status = synchronized(lock) {
                if (!disposed) coordinator.refresh()
                buildStatusLocked()
            }
            onComplete(status)
        }
    }

    /**
     * Posted to the host thread on purpose.
     *
     * Resuming with the tab already open reconciles straight into a TAKE_OVER,
     * and the attach is a blocking binder call whose remote side runs a full
     * EGL setup synchronously. Running that on the platform
     * thread stalls the UI on every foreground transition and can ANR when the
     * OEM GL thread is busy. Only the *detach* ordering is load-bearing (R4),
     * and that is [onActivityPaused]'s job — deferring the attach is safe.
     */
    fun onActivityResumed() {
        hostHandler.post {
            synchronized(lock) {
                if (!disposed) coordinator.setActivityResumed(true)
            }
        }
    }

    /**
     * R4. Main thread, synchronous, never posted. The OEM AndroidAutoActivity
     * creates its SurfaceView after this returns; any detach that lands later
     * tears down the EGL state it just built and leaves it black.
     */
    fun onActivityPaused() {
        synchronized(lock) {
            coordinator.setActivityResumed(false)
        }
    }

    /** Snapshot under [lock], safe to call from any thread. */
    fun status(): AndroidAutoStatus = synchronized(lock) { buildStatusLocked() }

    fun dispose() {
        synchronized(lock) {
            if (disposed) return
            disposed = true
            cancelRepairs()
            coordinator.setDartActive(false)
            coordinator.setSurfaceReady(false)
            service = null
            coordinator.setServiceConnected(false)
            hostError = null
            // Resources held by the platform objects are released on the main
            // looper below; the binder record is dropped here.
            if (bindingActive) {
                bindingActive = false
                runCatching { context.unbindService(serviceConnection) }
            }
        }
        mainHandler.post { releasePlatformTexture() }
        hostHandler.removeCallbacksAndMessages(null)
        hostThread.quitSafely()
    }

    // --- Binding ---

    private fun exfeatureIntent() =
        Intent(AndroidAutoContract.EXFEATURE_ACTION).setPackage(AndroidAutoContract.PACKAGE)

    private fun serviceAvailable(): Boolean =
        context.packageManager.queryIntentServices(exfeatureIntent(), 0).isNotEmpty()

    private fun bindLocked() {
        if (bindingActive || service != null) return
        val accepted = runCatching {
            context.bindService(exfeatureIntent(), serviceConnection, Context.BIND_AUTO_CREATE)
        }.getOrDefault(false)
        bindingActive = accepted
        if (!accepted) {
            // bindService can leak its registration record when it fails.
            runCatching { context.unbindService(serviceConnection) }
            hostError = "BIND_FAILED"
        }
    }

    private fun unbindLocked() {
        if (!bindingActive) return
        bindingActive = false
        service = null
        coordinator.setServiceConnected(false)
        runCatching { context.unbindService(serviceConnection) }
    }

    // --- Texture ---

    /**
     * Host thread, under [lock]. The caller must already have driven
     * `setSurfaceReady(false)` so the detach precedes the buffer free (R8).
     */
    private fun createTexture(width: Int, height: Int) {
        mainHandler.post { createPlatformTexture(width, height) }
    }

    /**
     * Main looper: `TextureRegistry` and `Surface` are platform-thread-only.
     *
     * This deliberately does **not** touch the coordinator. Marking the surface
     * ready here would reconcile — and therefore attach — on the platform
     * thread whenever the service happened to bind first, which is the same
     * blocking-EGL-on-the-UI-thread problem [onActivityResumed] avoids. The
     * reconcile is handed back to the host thread instead.
     */
    private fun createPlatformTexture(width: Int, height: Int) {
        synchronized(lock) {
            if (disposed) return
            if (entry != null && bufferWidth == width && bufferHeight == height) return
            surface?.release()
            surface = null
            entry?.release()
            entry = null
            val made = textures.createSurfaceTexture()
            made.surfaceTexture().setDefaultBufferSize(width, height)
            entry = made
            surface = Surface(made.surfaceTexture())
            bufferWidth = width
            bufferHeight = height
        }
        hostHandler.post { markSurfaceReady(width, height) }
    }

    /** Host thread: the reconcile — and any attach it triggers — lands here. */
    private fun markSurfaceReady(width: Int, height: Int) {
        synchronized(lock) {
            if (disposed) return
            // A newer activate() may have replaced the texture while this hop
            // was in flight; that call owns the reconcile for its own geometry.
            if (entry == null || bufferWidth != width || bufferHeight != height) return
            coordinator.setBufferSize(width, height)
            coordinator.setSurfaceReady(true)
            publishStatusLocked()
        }
    }

    /**
     * Host thread, under [lock]. R8: `detach` (via `setSurfaceReady(false)`,
     * synchronously here) → `Surface.release()` → `SurfaceTextureEntry.release()`
     * (on the main looper, below).
     */
    private fun releaseTexture() {
        coordinator.setSurfaceReady(false)
        mainHandler.post { releasePlatformTexture() }
    }

    /**
     * Main looper. No `disposed` guard on purpose: `dispose()` schedules this so
     * the buffers are still freed on teardown. Idempotent.
     */
    private fun releasePlatformTexture() {
        synchronized(lock) {
            surface?.release()
            surface = null
            entry?.release()
            entry = null
            bufferWidth = 0
            bufferHeight = 0
            publishStatusLocked()
        }
    }

    private fun resolveGeometry(width: Int?, height: Int?): Pair<Int, Int> {
        val overrideInvalid = (width != null && width <= 0) || (height != null && height <= 0)
        if (overrideInvalid) {
            // R7: reject the override, fall back to the default, and say so.
            hostError = "INVALID_BUFFER_SIZE"
        } else if (hostError == "INVALID_BUFFER_SIZE") {
            hostError = null
        }
        if (width != null && width > 0 && height != null && height > 0) return width to height
        return defaultBufferSize()
    }

    private fun defaultBufferSize(): Pair<Int, Int> {
        val metrics = DisplayMetrics()
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics) // minSdk 28
        val w = metrics.widthPixels
        val h = metrics.heightPixels
        return if (w > 0 && h > 0) {
            w to h
        } else {
            AndroidAutoContract.DEFAULT_BUFFER_WIDTH to AndroidAutoContract.DEFAULT_BUFFER_HEIGHT
        }
    }

    // --- Watchdog (R3) ---

    private var lastReportedAttached = false

    private fun onCoordinatorChanged() {
        // Called from the coordinator under `lock` (the coordinator only runs
        // inside a synchronized block in this class).
        val attached = coordinator.attached
        if (attached && !lastReportedAttached) {
            scheduleRepairs()
        } else if (!attached && lastReportedAttached) {
            cancelRepairs()
        }
        lastReportedAttached = attached
        publishStatusLocked()
    }

    private fun scheduleRepairs() {
        cancelRepairs()
        for (delay in AndroidAutoContract.REFRESH_DELAYS_MS) {
            hostHandler.postDelayed(repairTask, delay)
        }
        if (AndroidAutoContract.HEARTBEAT_MS > 0) {
            // Delayed, not immediate: posting with no delay fired a redundant
            // re-attach microseconds after the takeover's own attach.
            hostHandler.postDelayed(heartbeatTask, AndroidAutoContract.HEARTBEAT_MS)
        }
    }

    private fun cancelRepairs() {
        hostHandler.removeCallbacks(repairTask)
        hostHandler.removeCallbacks(heartbeatTask)
    }

    // --- Status ---

    private fun buildStatusLocked(): AndroidAutoStatus = AndroidAutoStatus(
        available = available,
        bound = service != null,
        attached = coordinator.attached,
        activityResumed = coordinator.inputs.activityResumed,
        dartActive = coordinator.inputs.dartActive,
        textureId = entry?.id(),
        bufferWidth = bufferWidth,
        bufferHeight = bufferHeight,
        attachCount = coordinator.attachCount,
        lastError = hostError ?: coordinator.lastError,
    )

    private fun publishStatusLocked() {
        onStatus(buildStatusLocked())
    }

    // --- Helpers ---

    private fun runOnHost(block: () -> Unit) {
        hostHandler.post {
            synchronized(lock) {
                if (!disposed) block()
            }
        }
    }

    private fun onRemoteFailure(t: Throwable) {
        hostError = "REMOTE_EXCEPTION"
        service = null
        coordinator.setServiceConnected(false)
    }

    /** R9: every binder call is wrapped; a dead remote never escapes. */
    private inner class BinderRenderGateway : AndroidAutoRenderGateway {
        override fun attach(width: Int, height: Int): Boolean {
            val manager = service ?: return false
            val target = surface ?: return false
            if (!target.isValid || width <= 0 || height <= 0) return false
            return runCatching {
                manager.notifyMainSurfaceAttached(target, width, height)
                // R5 has no Android Auto equivalent: this service exports no
                // `updateViewArea`. `q.i()` recalculates the view area from the
                // width and height passed here, which is why R7 rejects a zero.
                //
                // This call also sends a Carlink projection-focus message
                // (`c2.d.b().m(true, (byte) 0, true)`). It is why the heartbeat
                // in the contract is off — see `HEARTBEAT_MS`.
            }.onFailure { onRemoteFailure(it) }.isSuccess
        }

        override fun detach(): Boolean {
            val manager = service ?: return false
            return runCatching { manager.notifyMainSurfaceDetached() }
                .onFailure { onRemoteFailure(it) }
                .isSuccess
        }
    }
}
