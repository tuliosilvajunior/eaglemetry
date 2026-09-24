package com.timhss.capyenergy.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.timhss.capyenergy.MainActivity
import com.timhss.capyenergy.R
import com.timhss.capyenergy.concurrent.namedSingleThreadScheduledExecutor
import com.timhss.capyenergy.ifw.IntentFirewallManager
import com.timhss.capyenergy.roadcast.RoadcastDaemon
import com.timhss.capyenergy.telemetry.TelemetryRuntime
import com.timhss.capyenergy.telemetry.TelemetrySettings
import com.timhss.capyenergy.update.AppUpdateInstallGate
import com.timhss.capyenergy.update.AppUpdateManager
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class TelemetryCollectorService : Service() {
    private val roadcastWatchdog = namedSingleThreadScheduledExecutor("roadcast-watch")
    private val appUpdateWatchdog = namedSingleThreadScheduledExecutor("app-update")
    private lateinit var roadcastDaemon: RoadcastDaemon
    private lateinit var appUpdateManager: AppUpdateManager
    private var roadcastWatchdogTask: ScheduledFuture<*>? = null
    private var appUpdateWatchdogTask: ScheduledFuture<*>? = null

    override fun onCreate() {
        super.onCreate()
        startForeground()
        roadcastDaemon = RoadcastDaemon(applicationContext)
        startRoadcastWatchdog()
        val telemetryRuntime = TelemetryRuntime.get(applicationContext)
        telemetryRuntime.start()
        appUpdateManager = AppUpdateManager(
            applicationContext,
            activeSessionProvider = { telemetryRuntime.activeSessionType() }
        )
        startAppUpdateWatchdog(telemetryRuntime)

        // The charging auto-open needs nothing started here: it hangs off the
        // charge detector inside `TelemetryRuntime`, which is already running.
        val settings = TelemetrySettings(applicationContext)

        // The projection auto-open does need it. Its signal is a phone, and
        // the only object that watched for one lived in the Flutter engine, so
        // with the app closed nothing was looking. This service is what runs
        // whether or not the app is open.
        ProjectionAutoOpenSupervisor.get(applicationContext)
            .setEnabled(settings.projectionBetaEnabled())

        // The firewall rules are written through the local root shell, so this
        // rides the watchdog's thread rather than a second one, and waits for
        // the same adbd the daemon needs. The rules survive a reboot on their
        // own; this only puts them back in step with the settings.
        val ifw = IntentFirewallManager(applicationContext)
        roadcastWatchdog.schedule(
            {
                ifw.syncAll(
                    blockAutoEnergy = settings.replaceOemChargingEnabled()
                )
            },
            IFW_SYNC_DELAY_SECONDS,
            TimeUnit.SECONDS
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        TelemetryRuntime.get(applicationContext).start()
        return START_STICKY
    }

    override fun onDestroy() {
        TelemetryRuntime.get(applicationContext).stop()
        roadcastWatchdogTask?.cancel(false)
        roadcastWatchdogTask = null
        roadcastWatchdog.shutdown()
        appUpdateWatchdogTask?.cancel(false)
        appUpdateWatchdogTask = null
        appUpdateWatchdog.shutdown()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForeground() {
        ensureNotificationChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.telemetry_notification_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.telemetry_notification_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or pendingIntentImmutableFlag()
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(Notification.PRIORITY_LOW)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(getString(R.string.telemetry_notification_title))
            .setContentText(getString(R.string.telemetry_notification_text))
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun pendingIntentImmutableFlag(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }

    private fun startRoadcastWatchdog() {
        roadcastWatchdog.execute {
            reportRoadcastStatus(roadcastDaemon.ensureRunning())
        }
        roadcastWatchdogTask = roadcastWatchdog.scheduleWithFixedDelay(
            {
                runCatching {
                    roadcastDaemon.ensureRunning()
                }.onSuccess(::reportRoadcastStatus)
                    .onFailure { error ->
                        Log.w(TAG, "Roadcast watchdog failed", error)
                    }
            },
            ROADCAST_WATCHDOG_SECONDS,
            ROADCAST_WATCHDOG_SECONDS,
            TimeUnit.SECONDS
        )
    }

    /**
     * Retries every minute rather than watching for connectivity: the head
     * unit's network comes and goes with cell coverage and Wi-Fi hotspots the
     * app has no visibility into, so the simplest correct thing is to keep
     * asking. A failed check (typically no internet) is expected and logged
     * quietly; only a failed *install* — a corrupt download, a signature
     * mismatch — is worth a warning, since that is the app's own logic, not
     * the network.
     */
    private fun startAppUpdateWatchdog(telemetryRuntime: TelemetryRuntime) {
        appUpdateWatchdog.execute { checkAndInstallAppUpdate(telemetryRuntime) }
        appUpdateWatchdogTask = appUpdateWatchdog.scheduleWithFixedDelay(
            { checkAndInstallAppUpdate(telemetryRuntime) },
            APP_UPDATE_CHECK_INTERVAL_SECONDS,
            APP_UPDATE_CHECK_INTERVAL_SECONDS,
            TimeUnit.SECONDS
        )
    }

    private fun checkAndInstallAppUpdate(telemetryRuntime: TelemetryRuntime) {
        val status = runCatching { appUpdateManager.check() }.getOrElse { error ->
            Log.d(TAG, "App update check skipped: ${error.message}")
            return
        }
        if (!status.updateAvailable || !status.compatible) return
        if (AppUpdateInstallGate.isScheduled(status.availableVersionCode)) return
        runCatching {
            appUpdateManager.downloadAndInstall(
                beforeInstall = { telemetryRuntime.ensureRoadcastUpdatedForAppInstall() }
            )
        }.onSuccess {
            Log.i(TAG, "Background app update installed: ${status.availableVersionName}")
        }.onFailure { error ->
            Log.w(TAG, "Background app update install failed", error)
        }
    }

    private fun reportRoadcastStatus(status: RoadcastDaemon.Status) {
        if (status.running && status.socketReachable) {
            if (status.startedByApp) {
                Log.i(TAG, "Roadcast started by the app")
            }
            return
        }
        Log.w(
            TAG,
            "Roadcast unhealthy: running=${status.running} " +
                "socketReachable=${status.socketReachable} error=${status.error}"
        )
    }

    companion object {
        private const val TAG = "TelemetryCollector"
        private const val CHANNEL_ID = "telemetry_collection"
        private const val NOTIFICATION_ID = 41_001
        private const val ROADCAST_WATCHDOG_SECONDS = 10L
        private const val IFW_SYNC_DELAY_SECONDS = 5L
        private const val APP_UPDATE_CHECK_INTERVAL_SECONDS = 60L

        fun start(context: Context) {
            val appContext = context.applicationContext
            val intent = Intent(appContext, TelemetryCollectorService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appContext.startForegroundService(intent)
            } else {
                appContext.startService(intent)
            }
        }
    }
}
