package com.timhss.capyenergy.projection

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart ↔ Kotlin channel pair for projection presence. Same shape as
 * `CarplayBridge`: built in `MainActivity.configureFlutterEngine`, disposed in
 * `cleanUpFlutterEngine`, handlers cleared on dispose.
 *
 * It is a **separate** channel from `com.timhss.capyenergy/carplay` on
 * purpose. Presence is a different question with a different source, and
 * folding it into the render status would let a disconnected phone look like a
 * failed attach.
 *
 * MethodChannel   `com.timhss.capyenergy/projection`
 * EventChannel    `com.timhss.capyenergy/projection/presence`
 */
class ProjectionPresenceBridge(
    context: Context,
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        CHANNEL_NAME,
    )
    private val presenceChannel = EventChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        PRESENCE_CHANNEL_NAME,
    )

    @Volatile
    private var sink: EventChannel.EventSink? = null

    private val monitor = ProjectionPresenceMonitor(
        context = context,
        onSnapshot = { snapshot -> publish(snapshot) },
    )

    init {
        channel.setMethodCallHandler(this)
        presenceChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    publish(monitor.snapshot())
                    // Starting on the first listener, not in the constructor,
                    // keeps the probes unbound for a user who never opens a
                    // projection surface. Nothing binds until Dart asks.
                    monitor.start()
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            },
        )
    }

    /**
     * `getPresence` starts the monitor as well as reading it, for the same
     * reason `getStatus` binds: a caller that only ever reads must not be stuck
     * on UNKNOWN forever behind a start it never triggers.
     *
     * It answers the snapshot it has now and does not wait for the re-read the
     * monitor posts. The reply is therefore the last known truth, and the fresh
     * one arrives on the event channel a moment later.
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPresence" -> {
                monitor.start()
                result.success(monitor.snapshot().toMap())
            }

            "refresh" -> {
                monitor.refresh()
                result.success(monitor.snapshot().toMap())
            }

            else -> result.notImplemented()
        }
    }

    /** Re-reads the getters, because edges sent while we were away are lost. */
    fun onActivityResumed() = monitor.refresh()

    private fun publish(snapshot: ProjectionPresenceSnapshot) {
        val events = sink ?: return
        // `EventSink` is not thread-safe and the monitor publishes from its own
        // handler thread.
        mainHandler.post { events.success(snapshot.toMap()) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        presenceChannel.setStreamHandler(null)
        sink = null
        monitor.dispose()
    }

    companion object {
        const val CHANNEL_NAME = "com.timhss.capyenergy/projection"
        const val PRESENCE_CHANNEL_NAME = "com.timhss.capyenergy/projection/presence"
    }
}
