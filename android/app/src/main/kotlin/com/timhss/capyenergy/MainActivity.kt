package com.timhss.capyenergy

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import com.timhss.capyenergy.bridge.TelemetryBridge
import com.timhss.capyenergy.androidauto.AndroidAutoBridge
import com.timhss.capyenergy.carplay.CarplayBridge
import com.timhss.capyenergy.projection.ProjectionPresenceBridge
import com.timhss.capyenergy.projection.ProjectionTouchBridge
import com.timhss.capyenergy.service.TelemetryCollectorService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var telemetryBridge: TelemetryBridge? = null
    private var carplayBridge: CarplayBridge? = null
    private var androidAutoBridge: AndroidAutoBridge? = null
    private var projectionBridge: ProjectionPresenceBridge? = null
    private var projectionTouchBridge: ProjectionTouchBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        applyThemeWindowBackground()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        TelemetryCollectorService.start(applicationContext)
        val bridge = TelemetryBridge(this, flutterEngine)
        telemetryBridge = bridge
        carplayBridge = CarplayBridge(this, flutterEngine)
        androidAutoBridge = AndroidAutoBridge(this, flutterEngine)
        projectionBridge = ProjectionPresenceBridge(this, flutterEngine)
        projectionTouchBridge = ProjectionTouchBridge(this, flutterEngine)

        consumeDestination(intent, bridge)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeDestination(intent, telemetryBridge)
    }

    /**
     * Reads the destination a launcher outside the app asked for, and removes
     * it from the intent. The activity keeps its launch intent, so an extra
     * left in place would re-open that screen on every configuration change.
     */
    private fun consumeDestination(intent: Intent?, bridge: TelemetryBridge?) {
        val destination = intent?.getStringExtra(TelemetryBridge.EXTRA_DESTINATION) ?: return
        intent.removeExtra(TelemetryBridge.EXTRA_DESTINATION)
        bridge?.onDestinationRequested(destination)
    }

    override fun onResume() {
        super.onResume()
        applyThemeWindowBackground()
        carplayBridge?.onActivityResumed()
        androidAutoBridge?.onActivityResumed()
        // Edges broadcast while this process was away are lost, so resuming
        // re-reads the getters rather than trusting the last edge we saw.
        projectionBridge?.onActivityResumed()
    }

    private fun applyThemeWindowBackground() {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val colorHex = prefs.getString("flutter.launch_bg_color", null)
            if (colorHex != null) {
                val color = Color.parseColor(colorHex)
                window.setBackgroundDrawable(ColorDrawable(color))
                window.decorView.setBackgroundColor(color)
            }
        } catch (_: Exception) {
            // Ignored when prefs are unavailable or parsing fails
        }
    }

    override fun onPause() {
        // R4, for both projection stacks. The OEM CarplayActivity — and the
        // OEM AutoActivity — create their SurfaceView after this returns; any
        // detach that lands later tears down the render state they just built
        // and leaves them black with nothing to re-trigger it.
        // Synchronous, before super, on the main thread. Do not post either.
        carplayBridge?.onActivityPaused()
        androidAutoBridge?.onActivityPaused()
        // A finger that was down when the card went away never gets its UP from
        // the pointer stream, and the phone holds the press until one arrives.
        projectionTouchBridge?.onActivityPaused()
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        projectionTouchBridge?.dispose()
        projectionTouchBridge = null
        projectionBridge?.dispose()
        projectionBridge = null
        androidAutoBridge?.dispose()
        androidAutoBridge = null
        carplayBridge?.dispose()
        carplayBridge = null
        telemetryBridge?.dispose()
        telemetryBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
