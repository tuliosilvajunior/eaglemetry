package com.timhss.capyenergy.diagnostics

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.sqrt
import io.flutter.plugin.common.EventChannel

/**
 * Streams the head-unit IMU to Flutter for a live "sensor lab" view: watch the
 * car's tilt (pitch/roll) and feel road events (bumps, hard braking, cornering)
 * while driving.
 *
 * This MTK head unit lists fused GRAVITY / LINEAR_ACCELERATION sensors but they
 * emit no events (verified via dumpsys sensorservice: registered + active but
 * zero "last events"). Only the raw ACCELEROMETER delivers. So we drive off the
 * raw accelerometer and derive both parts ourselves:
 *  - gravity via a low-pass filter (defines "down" in the device frame,
 *    independent of how the tablet is mounted; its tilt gives pitch/roll);
 *  - linear acceleration = raw - gravity, then projected onto the gravity axis
 *    for vertical accel (potholes) with the remainder as horizontal accel
 *    (braking / accelerating / cornering).
 *
 * The accelerometer is sampled as fast as the platform allows so short impact
 * peaks are not missed; emissions to Flutter are throttled and carry the
 * peak-hold since the last frame so a brief spike still reaches the UI.
 */
class SensorLabStreamer(
    context: Context
) : EventChannel.StreamHandler {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val sensorManager =
        appContext.getSystemService(Context.SENSOR_SERVICE) as? SensorManager

    @Volatile private var sink: EventChannel.EventSink? = null

    // Low-pass gravity estimate (device frame) and derived tilt.
    private var gx = 0f
    private var gy = 0f
    private var gz = 0f
    private var haveGravity = false
    private var pitchDeg = 0f
    private var rollDeg = 0f
    private var lastEventNanos = 0L

    // Latest linear acceleration and peak-hold accumulators since last emit.
    private var linX = 0f
    private var linY = 0f
    private var linZ = 0f
    private var vertical = 0f
    private var horizontal = 0f
    private var peakVertical = 0f
    private var peakHorizontal = 0f
    private var peakMagnitude = 0f
    private var sampleCount = 0
    private var lastEmitElapsedMs = 0L

    private val listener = object : SensorEventListener {
        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

        override fun onSensorChanged(event: SensorEvent) {
            if (event.sensor.type == Sensor.TYPE_ACCELEROMETER) onAccelerometer(event)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        val manager = sensorManager
        val target = events
        if (manager == null || target == null) {
            events?.error("SENSOR_LAB_UNAVAILABLE", "SensorManager not available", null)
            return
        }
        stop()
        sink = target
        resetState()
        val accelerometer = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        if (accelerometer == null) {
            target.error("SENSOR_LAB_UNAVAILABLE", "No accelerometer on this device", null)
            sink = null
            return
        }
        // FASTEST so short pothole/impact peaks are captured.
        manager.registerListener(listener, accelerometer, SensorManager.SENSOR_DELAY_FASTEST)
    }

    override fun onCancel(arguments: Any?) {
        stop()
    }

    fun dispose() {
        stop()
    }

    private fun onAccelerometer(event: SensorEvent) {
        val ax = event.values[0]
        val ay = event.values[1]
        val az = event.values[2]

        // Low-pass the raw accelerometer to isolate gravity. Alpha is derived
        // from the actual sample interval for a stable ~0.5 s time constant.
        if (!haveGravity) {
            gx = ax
            gy = ay
            gz = az
            haveGravity = true
        } else {
            val dt = ((event.timestamp - lastEventNanos) / 1_000_000_000.0)
                .coerceIn(0.001, 0.05)
            val alpha = (GRAVITY_TAU_SECONDS / (GRAVITY_TAU_SECONDS + dt)).toFloat()
            gx = alpha * gx + (1 - alpha) * ax
            gy = alpha * gy + (1 - alpha) * ay
            gz = alpha * gz + (1 - alpha) * az
        }
        lastEventNanos = event.timestamp

        val gNorm = sqrt(gx * gx + gy * gy + gz * gz)
        if (gNorm < 1e-3f) return
        val ux = gx / gNorm
        val uy = gy / gNorm
        val uz = gz / gNorm
        // Tilt of the device relative to level. Carries the fixed dash-mount
        // offset; the UI zeroes it on a "calibrate on level ground" tap.
        pitchDeg = Math.toDegrees(atan2(uz.toDouble(), sqrt((ux * ux + uy * uy).toDouble()))).toFloat()
        rollDeg = Math.toDegrees(atan2(ux.toDouble(), uy.toDouble())).toFloat()

        // Linear acceleration = raw minus gravity estimate.
        linX = ax - gx
        linY = ay - gy
        linZ = az - gz
        val magnitude = sqrt(linX * linX + linY * linY + linZ * linZ)
        // Split into vertical (along gravity) and horizontal (the rest).
        vertical = linX * ux + linY * uy + linZ * uz
        val hx = linX - vertical * ux
        val hy = linY - vertical * uy
        val hz = linZ - vertical * uz
        horizontal = sqrt(hx * hx + hy * hy + hz * hz)

        if (abs(vertical) > abs(peakVertical)) peakVertical = vertical
        if (horizontal > peakHorizontal) peakHorizontal = horizontal
        if (magnitude > peakMagnitude) peakMagnitude = magnitude
        sampleCount += 1
        maybeEmit()
    }

    private fun maybeEmit() {
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastEmitElapsedMs < EMIT_INTERVAL_MS) return
        lastEmitElapsedMs = now
        val payload = mapOf(
            "pitchDeg" to pitchDeg,
            "rollDeg" to rollDeg,
            "haveGravity" to haveGravity,
            "linX" to linX,
            "linY" to linY,
            "linZ" to linZ,
            "vertical" to vertical,
            "horizontal" to horizontal,
            "peakVertical" to peakVertical,
            "peakHorizontal" to peakHorizontal,
            "peakMagnitude" to peakMagnitude,
            "sampleCount" to sampleCount
        )
        val target = sink
        peakVertical = 0f
        peakHorizontal = 0f
        peakMagnitude = 0f
        sampleCount = 0
        if (target != null) {
            mainHandler.post { target.success(payload) }
        }
    }

    private fun resetState() {
        gx = 0f
        gy = 0f
        gz = 0f
        haveGravity = false
        lastEventNanos = 0L
        peakVertical = 0f
        peakHorizontal = 0f
        peakMagnitude = 0f
        sampleCount = 0
        lastEmitElapsedMs = 0L
    }

    private fun stop() {
        sensorManager?.unregisterListener(listener)
        sink = null
    }

    companion object {
        private const val EMIT_INTERVAL_MS = 100L
        private const val GRAVITY_TAU_SECONDS = 0.5
    }
}
