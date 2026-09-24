package com.timhss.capyenergy.debug

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.telemetry.TelemetrySettings
import com.timhss.capyenergy.vehicle.VehiclePropertyHelper
import com.timhss.capyenergy.vehicle.VhalTestCommand
import com.timhss.capyenergy.vehicle.VhalTestRequest
import com.timhss.capyenergy.vehicle.VhalTestRunner

/**
 * Runs VHAL test commands off the broadcast thread.
 *
 * A Service rather than work inside [VhalTestReceiver.onReceive] for two reasons:
 * a sweep holds each value for seconds and would outlive the receiver, and keeping
 * one [VehiclePropertyHelper] alive across commands avoids reconnecting to the Car
 * service on every adb call.
 *
 * Not exported: only [VhalTestReceiver], inside this app, starts it.
 */
class VhalTestService : Service() {
    private val executor = namedSingleThreadExecutor("vhal-test")
    private val helper by lazy {
        VehiclePropertyHelper(applicationContext) { TelemetrySettings(applicationContext).packCapacityWh() }
    }
    private val runner by lazy {
        VhalTestRunner(access = helper, log = { line -> Log.i(VhalTestRunner.LOG_TAG, line) })
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val request = intent?.toRequest()
        if (request == null) {
            Log.w(VhalTestRunner.LOG_TAG, "ignored start without command extras")
            return START_NOT_STICKY
        }

        val command = try {
            VhalTestCommand.parse(request)
        } catch (error: IllegalArgumentException) {
            // Rejected before touching the Car service, so nothing was half-applied.
            Log.w(VhalTestRunner.LOG_TAG, "rejected: ${error.message}")
            return START_NOT_STICKY
        }

        executor.execute {
            try {
                runner.run(command)
            } catch (error: Throwable) {
                Log.e(VhalTestRunner.LOG_TAG, "command failed: ${command.javaClass.simpleName}", error)
            }
            if (command is VhalTestCommand.Stop) stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        executor.shutdownNow()
        runCatching { helper.disconnect() }
        Log.i(VhalTestRunner.LOG_TAG, "test service stopped")
        super.onDestroy()
    }

    private fun Intent.toRequest(): VhalTestRequest? {
        if (!hasExtra(EXTRA_OP)) return null
        return VhalTestRequest(
            op = getStringExtra(EXTRA_OP),
            propertyId = optInt(EXTRA_PROP),
            propertyIdHex = getStringExtra(EXTRA_PROP_HEX),
            areaId = optInt(EXTRA_AREA),
            value = optInt(EXTRA_VALUE),
            from = optInt(EXTRA_FROM),
            to = optInt(EXTRA_TO),
            delayMillis = optInt(EXTRA_DELAY_MS),
        )
    }

    private fun Intent.optInt(key: String): Int? =
        if (hasExtra(key)) getIntExtra(key, 0) else null

    companion object {
        const val EXTRA_OP = "op"
        const val EXTRA_PROP = "prop"
        const val EXTRA_PROP_HEX = "propHex"
        const val EXTRA_AREA = "area"
        const val EXTRA_VALUE = "value"
        const val EXTRA_FROM = "from"
        const val EXTRA_TO = "to"
        const val EXTRA_DELAY_MS = "delayMs"

        val FORWARDED_INT_EXTRAS = listOf(
            EXTRA_PROP, EXTRA_AREA, EXTRA_VALUE, EXTRA_FROM, EXTRA_TO, EXTRA_DELAY_MS
        )

        fun start(context: Context, configure: Intent.() -> Unit) {
            val intent = Intent(context, VhalTestService::class.java).apply(configure)
            context.startService(intent)
        }
    }
}
