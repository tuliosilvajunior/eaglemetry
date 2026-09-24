package com.timhss.capyenergy.projection

import android.app.Activity
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart ↔ Kotlin channel pair for touch forwarding. Same shape as
 * `CarplayBridge`: built in `MainActivity.configureFlutterEngine`, disposed in
 * `cleanUpFlutterEngine`, handlers cleared on dispose.
 *
 * MethodChannel   `com.timhss.capyenergy/projection/touch`
 * EventChannel    `com.timhss.capyenergy/projection/touch/status`
 *
 * `send` answers on the platform thread without a hop. The policy that decides
 * it runs on the caller's thread by design (see [ProjectionTouchController]),
 * and a gesture cannot wait for a round trip through a handler to learn whether
 * its own DOWN was accepted.
 */
class ProjectionTouchBridge(
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

    private val controller = ProjectionTouchController(
        context = activity.applicationContext,
        onStatus = { status -> publish(status) },
    )

    init {
        channel.setMethodCallHandler(this)
        statusChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    publish(controller.status())
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            },
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> result.success(controller.status().toMap())

            "bind" -> withStack(call, result) { stack ->
                controller.bind(stack)
                result.success(controller.status().toMap())
            }

            "unbind" -> withStack(call, result) { stack ->
                controller.unbind(stack)
                result.success(controller.status().toMap())
            }

            "setBufferSize" -> withStack(call, result) { stack ->
                val width = call.argument<Int>("width")
                val height = call.argument<Int>("height")
                if (width == null || height == null) {
                    result.error("BAD_ARGUMENTS", "width and height are required", null)
                } else {
                    controller.setBufferSize(stack, width, height)
                    result.success(controller.status().toMap())
                }
            }

            "setCalibration" -> withStack(call, result) { stack ->
                controller.setCalibration(
                    stack,
                    // Every field defaults to the identity rather than to zero.
                    // A missing scale that became 0.0 would collapse the whole
                    // axis onto its centre line.
                    ProjectionTouchCalibration.of(
                        scaleX = call.argument<Double>("scaleX") ?: 1.0,
                        offsetX = call.argument<Double>("offsetX") ?: 0.0,
                        scaleY = call.argument<Double>("scaleY") ?: 1.0,
                        offsetY = call.argument<Double>("offsetY") ?: 0.0,
                    ),
                )
                result.success(controller.status().toMap())
            }

            "send" -> withStack(call, result) { stack -> send(call, result, stack) }

            "releaseGestures" -> {
                controller.releaseGestures()
                result.success(controller.status().toMap())
            }

            else -> result.notImplemented()
        }
    }

    /**
     * The reply says whether the touch was accepted, and when it was not, why.
     *
     * A refusal is not an error: a touch on the letterbox bar, or a second
     * finger on CarPlay, is the path working. `result.error` would make every
     * such touch throw in Dart.
     */
    private fun send(call: MethodCall, result: MethodChannel.Result, stack: ProjectionStack) {
        val action = call.argument<Int>("action")
        if (action == null) {
            result.error("BAD_ARGUMENTS", "action is required", null)
            return
        }
        val raw = call.argument<List<Map<String, Any?>>>("pointers")
        if (raw == null) {
            result.error("BAD_ARGUMENTS", "pointers is required", null)
            return
        }
        val pointers = raw.map { entry ->
            ProjectionTouchPointer(
                id = (entry["id"] as? Number)?.toInt() ?: 0,
                // A missing coordinate must not become 0.0: that is a real
                // corner of the screen. NaN is refused by the policy instead.
                x = (entry["x"] as? Number)?.toDouble() ?: Double.NaN,
                y = (entry["y"] as? Number)?.toDouble() ?: Double.NaN,
            )
        }
        val drop = controller.send(
            ProjectionTouchRequest(
                stack = stack,
                action = action,
                actionIndex = call.argument<Int>("actionIndex") ?: 0,
                pointers = pointers,
            ),
        )
        result.success(mapOf("sent" to (drop == null), "dropReason" to drop))
    }

    private inline fun withStack(
        call: MethodCall,
        result: MethodChannel.Result,
        block: (ProjectionStack) -> Unit,
    ) {
        val stack = ProjectionStack.fromWire(call.argument<String>("stack"))
        if (stack == null) {
            result.error("BAD_ARGUMENTS", "unknown stack", null)
            return
        }
        block(stack)
    }

    /** R4's neighbour: lift before the card can go away, never after. */
    fun onActivityPaused() = controller.releaseGestures()

    /**
     * `EventChannel.EventSink` is not thread-safe and the controller publishes
     * from its handler thread, so every event lands on the main looper.
     */
    private fun publish(status: ProjectionTouchStatus) {
        val events = sink ?: return
        mainHandler.post { events.success(status.toMap()) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        statusChannel.setStreamHandler(null)
        sink = null
        controller.dispose()
    }

    companion object {
        const val CHANNEL_NAME = "com.timhss.capyenergy/projection/touch"
        const val STATUS_CHANNEL_NAME = "com.timhss.capyenergy/projection/touch/status"
    }
}
