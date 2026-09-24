package com.timhss.capyenergy.projection

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock

/**
 * Which phone is connected.
 *
 * Three inputs, no timer:
 *  - a cold read of each getter when the monitor starts, which is what makes
 *    the answer right for a phone that was already connected before this app
 *    opened;
 *  - one [BroadcastReceiver] for both connection actions, for the edges;
 *  - a re-read on resume, because a broadcast sent while this process was dead
 *    is lost and the getters are cheap.
 *
 * Threading mirrors `CarplaySurfaceHost`: binder work runs on a dedicated
 * [HandlerThread], never on the platform thread.
 */
class ProjectionPresenceMonitor(
    context: Context,
    private val onSnapshot: (ProjectionPresenceSnapshot) -> Unit,
) {
    private val appContext = context.applicationContext
    private val lock = Any()

    private val thread = HandlerThread("ProjectionPresence").apply { start() }
    private val handler = Handler(thread.looper)

    private var carplay = PresenceState.UNKNOWN
    private var androidAuto = PresenceState.UNKNOWN
    private var carplayAvailable = false
    private var androidAutoAvailable = false
    private var carplayEdgeAt: Long? = null
    private var androidAutoEdgeAt: Long? = null
    private var started = false
    private var disposed = false

    private val carplayProbe = ProjectionPresenceProbe(
        context = appContext,
        action = ProjectionContract.CARPLAY_SESSION_ACTION,
        servicePackage = ProjectionContract.CARPLAY_PACKAGE,
        descriptor = ProjectionContract.CARPLAY_SESSION_DESCRIPTOR,
        transaction = ProjectionContract.TX_CARPLAY_IS_CONNECTED,
        onBindingChanged = { refresh() },
    )

    private val androidAutoProbe = ProjectionPresenceProbe(
        context = appContext,
        action = ProjectionContract.ANDROID_AUTO_DEVICELIST_ACTION,
        servicePackage = ProjectionContract.ANDROID_AUTO_PACKAGE,
        descriptor = ProjectionContract.ANDROID_AUTO_DEVICELIST_DESCRIPTOR,
        transaction = ProjectionContract.TX_ANDROID_AUTO_CURRENT_DEVICE,
        onBindingChanged = { refresh() },
    )

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val protocol = ProjectionPresenceParser.protocolOf(intent?.action) ?: return
            val notification = intent?.getStringExtra(ProjectionContract.EXTRA_NOTIFICATION)
            // Null means this broadcast was about something else — media, an
            // alert, a power request. It is not a disconnection.
            val state = ProjectionPresenceParser.stateFromNotification(notification) ?: return
            apply(protocol, state, SystemClock.elapsedRealtime())
        }
    }

    /** Registers the receiver and takes the first reading. Idempotent. */
    fun start() {
        synchronized(lock) {
            if (disposed || started) return
            started = true
        }
        val filter = IntentFilter().apply {
            addAction(ProjectionContract.CARPLAY_BROADCAST)
            addAction(ProjectionContract.ANDROID_AUTO_BROADCAST)
        }
        runCatching { appContext.registerReceiver(receiver, filter) }
        refresh()
    }

    /** Re-reads both getters. Call it on resume and after a binding changes. */
    fun refresh() {
        handler.post {
            synchronized(lock) { if (disposed) return@post }
            carplayProbe.ensureBound()
            androidAutoProbe.ensureBound()
            val cpAvailable = carplayProbe.available()
            val aaAvailable = androidAutoProbe.available()
            val cp = carplayProbe.read()
            val aa = androidAutoProbe.read()
            val snapshot = synchronized(lock) {
                if (disposed) return@post
                carplayAvailable = cpAvailable
                androidAutoAvailable = aaAvailable
                // A getter answers the current truth, so it may clear a
                // connected state as well as set one. The edge time is only
                // touched when the state changes, so a re-read that confirms
                // what we already knew does not reorder two live sessions.
                if (cp != carplay) {
                    carplay = cp
                    carplayEdgeAt = SystemClock.elapsedRealtime()
                }
                if (aa != androidAuto) {
                    androidAuto = aa
                    androidAutoEdgeAt = SystemClock.elapsedRealtime()
                }
                buildLocked()
            }
            onSnapshot(snapshot)
        }
    }

    fun snapshot(): ProjectionPresenceSnapshot = synchronized(lock) { buildLocked() }

    fun dispose() {
        synchronized(lock) {
            if (disposed) return
            disposed = true
        }
        runCatching { appContext.unregisterReceiver(receiver) }
        carplayProbe.dispose()
        androidAutoProbe.dispose()
        handler.removeCallbacksAndMessages(null)
        thread.quitSafely()
    }

    private fun apply(
        protocol: ProjectionPresenceParser.Protocol,
        state: PresenceState,
        at: Long,
    ) {
        val snapshot = synchronized(lock) {
            if (disposed) return
            when (protocol) {
                ProjectionPresenceParser.Protocol.CARPLAY -> {
                    if (carplay == state) return
                    carplay = state
                    carplayEdgeAt = at
                }

                ProjectionPresenceParser.Protocol.ANDROID_AUTO -> {
                    if (androidAuto == state) return
                    androidAuto = state
                    androidAutoEdgeAt = at
                }
            }
            buildLocked()
        }
        onSnapshot(snapshot)
    }

    private fun buildLocked() = ProjectionPresenceSnapshot(
        carplay = carplay,
        androidAuto = androidAuto,
        carplayAvailable = carplayAvailable,
        androidAutoAvailable = androidAutoAvailable,
        carplayEdgeAt = carplayEdgeAt,
        androidAutoEdgeAt = androidAutoEdgeAt,
    )
}
