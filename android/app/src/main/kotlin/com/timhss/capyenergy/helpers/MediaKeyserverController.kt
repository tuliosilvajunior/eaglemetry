package com.timhss.capyenergy.helpers

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log

class MediaKeyserverController(context: Context) {
    private val appContext = context.applicationContext

    fun disable(): KeyserverCommandResult {
        return runCatching {
            appContext.packageManager.setApplicationEnabledSetting(
                KEYSERVER_PACKAGE,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                0
            )
            KeyserverCommandResult(true, "disable", "keyserver disabled")
        }.getOrElse { error ->
            Log.e(TAG, "Failed to disable keyserver", error)
            KeyserverCommandResult(false, "disable", error.shortMessage())
        }
    }

    fun restore(): KeyserverCommandResult {
        val enable = runCatching {
            appContext.packageManager.setApplicationEnabledSetting(
                KEYSERVER_PACKAGE,
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT,
                0
            )
            true
        }.getOrElse { error ->
            Log.e(TAG, "Failed to enable keyserver", error)
            false
        }
        val start = runCatching {
            val intent = Intent(KEYSERVER_BOOT_ACTION).setClassName(
                KEYSERVER_PACKAGE,
                KEYSERVER_SERVICE
            )
            appContext.startForegroundService(intent)
            true
        }.getOrElse { error ->
            Log.e(TAG, "Failed to start keyserver service", error)
            false
        }
        val broadcast = if (start) {
            true
        } else {
            runCatching {
                appContext.sendBroadcast(Intent(KEYSERVER_BOOT_ACTION).setPackage(KEYSERVER_PACKAGE))
                true
            }.getOrElse { error ->
                Log.e(TAG, "Failed to send keyserver boot broadcast", error)
                false
            }
        }
        return KeyserverCommandResult(
            ok = enable && (start || broadcast),
            action = "restore",
            details = "enable=$enable startForegroundService=$start broadcast=$broadcast"
        )
    }

    fun ensureRestored(): KeyserverCommandResult = restore()

    private fun Throwable.shortMessage(): String =
        "${this::class.java.simpleName}: ${message ?: "no message"}"

    companion object {
        private const val TAG = "MediaKeyserverController"
        private const val KEYSERVER_PACKAGE = "com.flyme.auto.keyserver"
        private const val KEYSERVER_SERVICE = "com.flyme.auto.keyserver.service.AutoKeyService"
        private const val KEYSERVER_BOOT_ACTION = "com.geely.action.BOOT_KET_SERVICE_APP"
    }
}

data class KeyserverCommandResult(
    val ok: Boolean,
    val action: String,
    val details: String
)
