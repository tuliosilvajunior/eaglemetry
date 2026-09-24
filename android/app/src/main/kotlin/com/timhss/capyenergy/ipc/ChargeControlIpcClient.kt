package com.timhss.capyenergy.ipc

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.timhss.capyenergy.telemetry.TelemetrySettings

data class ChargeControlIpcState(
    val targetSoc: Int = 80,
    val amps: Int? = null,
    val minAmps: Int = 5,
    val maxAmps: Int = 32,
    val forceCharging: Boolean = false,
    /** Whether the last command Geely Charge Control answered was applied. */
    val lastCommandOk: Boolean = true,
    /** Why the last command failed, in the words the control app used. */
    val lastError: String? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "targetSoc" to targetSoc,
        "amps" to amps,
        "minAmps" to minAmps,
        "maxAmps" to maxAmps,
        "forceCharging" to forceCharging,
        "lastCommandOk" to lastCommandOk,
        "lastError" to lastError
    )

    /**
     * Folds one reply from Geely Charge Control into the shown state.
     *
     * Two rules, and the bug this screen had came from missing both. A reply
     * that failed changes nothing but the error, because its numbers are the
     * ones the caller asked for, not the ones the car holds. A value the reply
     * leaves out changes nothing either, because absent means unknown, not
     * zero.
     */
    fun merge(reply: ChargeControlReply): ChargeControlIpcState {
        if (!reply.success) {
            return copy(lastCommandOk = false, lastError = reply.error)
        }
        return copy(
            targetSoc = reply.targetSoc?.takeIf { it in 50..100 } ?: targetSoc,
            amps = reply.amps?.takeIf { it > 0 } ?: amps,
            minAmps = reply.minAmps?.takeIf { it > 0 } ?: minAmps,
            maxAmps = reply.maxAmps?.takeIf { it > 0 } ?: maxAmps,
            forceCharging = reply.forceCharging ?: forceCharging,
            lastCommandOk = true,
            lastError = null
        )
    }
}

/**
 * What Geely Charge Control answered, with every field absent unless the car
 * reported it.
 */
data class ChargeControlReply(
    val success: Boolean,
    val targetSoc: Int? = null,
    val amps: Int? = null,
    val minAmps: Int? = null,
    val maxAmps: Int? = null,
    val forceCharging: Boolean? = null,
    val error: String? = null
) {
    companion object {
        fun fromIntent(intent: Intent): ChargeControlReply = ChargeControlReply(
            success = intent.getBooleanExtra(ChargeControlIpcClient.EXTRA_SUCCESS, true),
            targetSoc = intent.intExtraOrNull(ChargeControlIpcClient.EXTRA_TARGET_SOC),
            amps = intent.intExtraOrNull(ChargeControlIpcClient.EXTRA_AMPS),
            minAmps = intent.intExtraOrNull(ChargeControlIpcClient.EXTRA_MIN_AMPS),
            maxAmps = intent.intExtraOrNull(ChargeControlIpcClient.EXTRA_MAX_AMPS),
            forceCharging = if (intent.hasExtra(ChargeControlIpcClient.EXTRA_FORCE_CHARGING)) {
                intent.getBooleanExtra(ChargeControlIpcClient.EXTRA_FORCE_CHARGING, false)
            } else {
                null
            },
            error = intent.getStringExtra(ChargeControlIpcClient.EXTRA_ERROR)
        )

        private fun Intent.intExtraOrNull(key: String): Int? =
            if (hasExtra(key)) getIntExtra(key, -1) else null
    }
}

class ChargeControlIpcClient(
    private val context: Context,
    private val settings: TelemetrySettings,
    private val onTargetSocChanged: (Int) -> Unit = {},
    private val onStateChanged: (ChargeControlIpcState) -> Unit = {}
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var registered = false

    private var currentState = ChargeControlIpcState(
        targetSoc = settings.chargeTargetSocPercent()
    )

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_STATE_CHANGED) return
            // A reply that arrives between the switch going off and the
            // unregister landing is not one this app asked for.
            if (!enabled()) return

            val reply = ChargeControlReply.fromIntent(intent)
            val merged = currentState.merge(reply)
            currentState = merged

            if (!reply.success) {
                Log.w(TAG, "Charge command refused: ${reply.error ?: "no reason given"}")
                mainHandler.post { onStateChanged(merged) }
                return
            }

            settings.setChargeTargetSocPercent(merged.targetSoc)
            Log.i(TAG, "Updated state from Geely Charge Control: $merged")
            mainHandler.post {
                onTargetSocChanged(merged.targetSoc)
                onStateChanged(merged)
            }
        }
    }

    /**
     * Whether the reader has handed charge control to Geely Charge Control.
     *
     * The switch in the settings is the whole rule, and it lives here so no
     * caller has to remember it. While it is off this app neither listens to
     * the control app nor speaks to it.
     */
    private fun enabled(): Boolean = settings.externalChargeControlEnabled()

    /**
     * Brings the link in step with the setting.
     *
     * Call it after the switch changes. On means registered and querying; off
     * means unregistered, silent, and holding nothing the reader could mistake
     * for a live reading.
     */
    fun syncToSetting() {
        if (enabled()) start() else stop()
    }

    fun start() {
        if (!enabled()) {
            stop()
            return
        }
        if (!registered) {
            val filter = IntentFilter(ACTION_STATE_CHANGED)
            try {
                context.registerReceiver(receiver, filter)
                registered = true
            } catch (e: Exception) {
                Log.w(TAG, "Failed to register ChargeControlReceiver", e)
            }
        }
        queryState()
    }

    fun stop() {
        if (registered) {
            try {
                context.unregisterReceiver(receiver)
            } catch (_: Exception) {}
            registered = false
        }
        // Nothing read from the car outlives the link. What is held now is a
        // reading that no longer has a source.
        currentState = ChargeControlIpcState(targetSoc = settings.chargeTargetSocPercent())
    }

    /**
     * Sends one command to Geely Charge Control.
     *
     * There is one delivery, not two. The control app answers on
     * ACTION_STATE_CHANGED once the car has answered it, and the reply is the
     * only thing that may change what this holds. Nothing is written here
     * hopefully: an amperage or a mode the vehicle never confirmed must never
     * reach the screen.
     */
    private fun sendCommand(action: String, extras: Intent.() -> Unit = {}) {
        if (!enabled()) {
            Log.i(TAG, "Skipped $action: external charge control is off")
            return
        }
        try {
            val intent = Intent(action).apply {
                setPackage(PACKAGE_NAME)
                component = ComponentName(PACKAGE_NAME, RECEIVER_CLASS)
                extras()
            }
            context.sendBroadcast(intent, PERMISSION_CHARGE_CONTROL)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to send $action", e)
        }
    }

    fun queryState() = sendCommand(ACTION_QUERY_STATE)

    fun getState(): ChargeControlIpcState = currentState

    /**
     * The target is a preference both apps hold, not a vehicle reading, so it
     * is stored here as well as sent.
     */
    fun setTargetSoc(percent: Int) {
        val clamped = percent.coerceIn(50, 100)
        settings.setChargeTargetSocPercent(clamped)
        currentState = currentState.copy(targetSoc = clamped)
        sendCommand(ACTION_SET_CHARGE_LIMIT) { putExtra(EXTRA_TARGET_SOC, clamped) }
    }

    fun setAmperage(amps: Int) {
        val clamped = amps.coerceIn(currentState.minAmps, currentState.maxAmps)
        sendCommand(ACTION_SET_AMPERAGE) { putExtra(EXTRA_AMPS, clamped) }
    }

    fun setForceCharging(enabled: Boolean) {
        sendCommand(ACTION_FORCE_CHARGING) { putExtra(EXTRA_FORCE_CHARGING, enabled) }
    }

    fun stopCharging() = sendCommand(ACTION_STOP_CHARGING)

    companion object {
        private const val TAG = "ChargeControlIpcClient"
        const val PACKAGE_NAME = "com.timhss.geelychargecontrol"
        const val RECEIVER_CLASS = "com.timhss.geelychargecontrol.ipc.ChargeControlReceiver"
        const val PERMISSION_CHARGE_CONTROL = "com.timhss.geelychargecontrol.permission.CHARGE_CONTROL"
        const val ACTION_SET_CHARGE_LIMIT = "com.timhss.geelychargecontrol.ACTION_SET_CHARGE_LIMIT"
        const val ACTION_SET_AMPERAGE = "com.timhss.geelychargecontrol.ACTION_SET_AMPERAGE"
        const val ACTION_FORCE_CHARGING = "com.timhss.geelychargecontrol.ACTION_FORCE_CHARGING"
        const val ACTION_STOP_CHARGING = "com.timhss.geelychargecontrol.ACTION_STOP_CHARGING"
        const val ACTION_QUERY_STATE = "com.timhss.geelychargecontrol.ACTION_QUERY_STATE"
        const val ACTION_STATE_CHANGED = "com.timhss.geelychargecontrol.ACTION_STATE_CHANGED"
        const val EXTRA_TARGET_SOC = "extra_target_soc"
        const val EXTRA_AMPS = "extra_amps"
        const val EXTRA_MIN_AMPS = "extra_min_amps"
        const val EXTRA_MAX_AMPS = "extra_max_amps"
        const val EXTRA_FORCE_CHARGING = "extra_force_charging"
        const val EXTRA_SUCCESS = "extra_success"
        const val EXTRA_ERROR = "extra_error"
    }
}
