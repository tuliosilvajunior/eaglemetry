package com.timhss.capyenergy.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.roadcast.RoadcastDaemon
import com.timhss.capyenergy.telemetry.TelemetrySettings

class TelemetryBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        val pendingResult = goAsync()
        val executor = namedSingleThreadExecutor("boot-start")
        executor.execute {
            try {
                val roadcast = RoadcastDaemon(context).ensureRunning()
                if (!roadcast.running || !roadcast.socketReachable) {
                    Log.w(TAG, "Roadcast bootstrap incomplete after $action: $roadcast")
                }

                if (TelemetrySettings(context).autoStartOnBoot()) {
                    TelemetryCollectorService.start(context)
                } else {
                    Log.i(TAG, "Telemetry collector auto-start disabled after $action")
                }
            } catch (error: Exception) {
                Log.w(TAG, "Boot initialization failed after $action", error)
            } finally {
                pendingResult.finish()
                executor.shutdown()
            }
        }
    }

    companion object {
        private const val TAG = "TelemetryBootReceiver"
    }
}
