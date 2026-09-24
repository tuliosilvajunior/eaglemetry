package com.timhss.capyenergy.carplay

import android.app.Activity
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart ↔ Kotlin channel pair for CarPlay. Mirrors `TelemetryBridge`'s shape:
 * constructed in `MainActivity.configureFlutterEngine`, disposed in
 * `cleanUpFlutterEngine`, handlers cleared on dispose.
 *
 * MethodChannel   `com.timhss.capyenergy/carplay`
 * EventChannel    `com.timhss.capyenergy/carplay/status`
 */
class CarplayBridge(
    activity: Activity,
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        CHANNEL_NAME,
    )
    private val statusChannel = EventChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        STATUS_CHANNEL_NAME,
    )

    /** Written on the platform thread, read from the host thread in [publish]. */
    @Volatile
    private var sink: EventChannel.EventSink? = null

    private val host = CarplaySurfaceHost(
        context = activity.applicationContext,
        textures = flutterEngine.renderer,
        onStatus = { status -> publish(status) },
    )

    init {
        channel.setMethodCallHandler(this)
        statusChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    publish(host.status())
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            },
        )
    }

    /**
     * Every reply carries the status the call actually produced.
     *
     * The host does its work on its own thread, so the mutating methods take a
     * completion callback rather than returning: reading `host.status()` right
     * after the call would race the posted work and hand Dart the *previous*
     * state — `activate` answering `dartActive: false` — non-deterministically.
     * `dart-flutter-ui.md` §2.2 promises the caller never needs a second read;
     * this is what makes that true.
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Binds (R1-safe: no attach — see `ensureBound`) rather than just
            // reading, so a shell that only ever calls `getStatus()` still sees
            // `bound` become true instead of stuck false forever.
            "getStatus" -> host.ensureBound { status -> reply(result, status) }

            "activate" -> host.activate(
                width = call.argument<Int>("width"),
                height = call.argument<Int>("height"),
            ) { status -> reply(result, status) }

            "deactivate" -> host.deactivate { status -> reply(result, status) }

            "refresh" -> host.requestRefresh { status -> reply(result, status) }

            else -> result.notImplemented()
        }
    }

    /** `MethodChannel.Result` must be answered on the platform thread. */
    private fun reply(result: MethodChannel.Result, status: CarplayStatus) {
        mainHandler.post { result.success(status.toMap()) }
    }

    fun onActivityResumed() = host.onActivityResumed()

    /** R4: synchronous, main thread, before `super.onPause()` in the host. */
    fun onActivityPaused() = host.onActivityPaused()

    /**
     * `EventChannel.EventSink` is not thread-safe and the host publishes from
     * its handler thread, so every event lands on the main looper.
     */
    private fun publish(status: CarplayStatus) {
        val events = sink ?: return
        mainHandler.post { events.success(status.toMap()) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        statusChannel.setStreamHandler(null)
        sink = null
        host.dispose()
    }

    companion object {
        const val CHANNEL_NAME = "com.timhss.capyenergy/carplay"
        const val STATUS_CHANNEL_NAME = "com.timhss.capyenergy/carplay/status"
    }
}
