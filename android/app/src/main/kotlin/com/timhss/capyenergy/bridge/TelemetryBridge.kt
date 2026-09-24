package com.timhss.capyenergy.bridge

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.timhss.capyenergy.bridge.generated.AnnotationsChangedStreamHandler
import com.timhss.capyenergy.bridge.generated.SessionsChangedStreamHandler
import com.timhss.capyenergy.bridge.generated.TelemetryWireApi
import com.timhss.capyenergy.concurrent.namedFixedThreadPool
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.diagnostics.SensorLabStreamer
import com.timhss.capyenergy.ifw.IntentFirewallManager
import com.timhss.capyenergy.service.ProjectionAutoOpenSupervisor
import com.timhss.capyenergy.service.TelemetryCollectorService
import com.timhss.capyenergy.telemetry.TelemetryRuntime
import com.timhss.capyenergy.telemetry.TelemetrySettings
import com.timhss.capyenergy.update.AppUpdateManager
import com.timhss.capyenergy.vehicle.HvacClimateController
import com.timhss.capyenergy.vehicle.VehiclePropertyHelper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class TelemetryBridge(
    private val activity: Activity,
    flutterEngine: FlutterEngine
) : MethodChannel.MethodCallHandler {
    private val appContext = activity.applicationContext
    private val helper = VehiclePropertyHelper(activity.applicationContext) {
        TelemetrySettings(activity.applicationContext).packCapacityWh()
    }
    private val hvacClimateController = HvacClimateController(helper)
    private val telemetryRuntime = TelemetryRuntime.get(activity.applicationContext)
    private val appUpdateManager = AppUpdateManager(
        appContext,
        activeSessionProvider = { telemetryRuntime.activeSessionType() }
    )
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
    private val eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, LIVE_CHANNEL_NAME)
    private val vehicleSpeedChannel =
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, VEHICLE_SPEED_CHANNEL_NAME)
    private val sensorLabStreamer = SensorLabStreamer(appContext)
    private val sensorLabChannel =
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SENSOR_LAB_CHANNEL_NAME)
    /**
     * Mutating calls: one thread, so they apply in the order Flutter sent them.
     */
    private val commandExecutor = namedSingleThreadExecutor("wire-command")

    /**
     * Read-only calls.
     *
     * Every bridge method used to share one thread, so the charging screen's
     * three opening calls ran strictly one after another — and behind any HVAC
     * or settings write already in flight. They have no ordering relationship
     * with each other, so Flutter can now issue them concurrently and actually
     * get concurrency.
     */
    private val queryExecutor = namedFixedThreadPool("wire-query", QUERY_THREADS)
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(telemetryRuntime.publisher)
        vehicleSpeedChannel.setStreamHandler(telemetryRuntime.vehicleSpeedPublisher)
        sensorLabChannel.setStreamHandler(sensorLabStreamer)
        // The typed half. Methods listed in `pigeons/telemetry_wire.dart` are
        // handled here and are deliberately absent from the `when` above.
        TelemetryWireApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            TelemetryWireHandler(telemetryRuntime)
        )
        SessionsChangedStreamHandler.register(
            flutterEngine.dartExecutor.binaryMessenger,
            SessionChangeStreamHandler(telemetryRuntime.sessionChanges)
        )
        AnnotationsChangedStreamHandler.register(
            flutterEngine.dartExecutor.binaryMessenger,
            AnnotationChangeStreamHandler(telemetryRuntime.annotationChanges)
        )
        telemetryRuntime.onTargetSocChangedListener = { targetSoc ->
            mainHandler.post {
                channel.invokeMethod(
                    "onChargeTargetSocChanged",
                    mapOf("targetSoc" to targetSoc)
                )
            }
        }
        telemetryRuntime.onChargeControlStateChanged = { state ->
            mainHandler.post {
                channel.invokeMethod(
                    "onChargeControlStateChanged",
                    state.toMap()
                )
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPlatformStatus" -> result.success(
                mapOf(
                    "ok" to true,
                    "platform" to "android",
                    "bridge" to CHANNEL_NAME,
                    "timestampMillis" to System.currentTimeMillis()
                )
            )
            "getTelemetrySnapshot" -> runQuery(result, "TELEMETRY_READ_FAILED") {
                helper.readTelemetrySnapshot().toMap()
            }
            "startTelemetryCollection" -> runBackground(result, "TELEMETRY_START_FAILED") {
                TelemetryCollectorService.start(appContext)
                telemetryRuntime.start()
                telemetryRuntime.collectorStatusMap()
            }
            "stopTelemetryCollection" -> runBackground(result, "TELEMETRY_STOP_FAILED") {
                appContext.stopService(Intent(appContext, TelemetryCollectorService::class.java))
                telemetryRuntime.stop()
                telemetryRuntime.collectorStatusMap()
            }
            "getCollectorStatus" -> result.success(telemetryRuntime.collectorStatusMap())
            "getVehicleCapabilities" -> result.success(telemetryRuntime.vehicleCapabilitiesMap())
            "getRoadcastStatus" -> result.success(telemetryRuntime.roadcastStatusMap())
            "getAppUpdateStatus" -> result.success(appUpdateManager.localStatus().toMap())
            "checkAppUpdate" -> runQuery(result, "APP_UPDATE_CHECK_FAILED") {
                appUpdateManager.check().toMap()
            }
            "installAppUpdate" -> runBackground(result, "APP_UPDATE_INSTALL_FAILED") {
                appUpdateManager.downloadAndInstall(
                    beforeInstall = { telemetryRuntime.ensureRoadcastUpdatedForAppInstall() }
                ).toMap()
            }
            "getRoadcastUpdateStatus" -> runBackground(result, "ROADCAST_UPDATE_STATUS_FAILED") {
                telemetryRuntime.roadcastUpdateStatusMap()
            }
            "checkRoadcastUpdate" -> runBackground(result, "ROADCAST_UPDATE_CHECK_FAILED") {
                telemetryRuntime.checkRoadcastUpdate()
            }
            "updateRoadcastDaemon" -> runBackground(result, "ROADCAST_UPDATE_FAILED") {
                telemetryRuntime.updateRoadcast()
            }
            "restartRoadcastDaemon" -> runBackground(result, "ROADCAST_RESTART_FAILED") {
                telemetryRuntime.restartRoadcast()
            }
            "getLiveTelemetrySnapshot" -> result.success(telemetryRuntime.latestSnapshotMap())
            "getHvacControlStatus" -> runQuery(result, "HVAC_CONTROL_STATUS_FAILED") {
                hvacClimateController.statusMap()
            }
            "stepHvacTemperature" -> runBackground(result, "HVAC_TEMPERATURE_STEP_FAILED") {
                val delta = call.argument<Number>("delta")?.toFloat() ?: 1f
                hvacClimateController.stepTemperature(delta)
            }
            "setHvacTemperature" -> {
                val value = call.argument<Number>("temperatureC")?.toFloat()
                if (value == null) {
                    result.error(
                        "HVAC_TEMPERATURE_REQUIRED",
                        "setHvacTemperature requires temperatureC",
                        null
                    )
                } else {
                    runBackground(result, "HVAC_TEMPERATURE_SET_FAILED") {
                        hvacClimateController.setTemperature(value)
                    }
                }
            }
            "stepHvacFanSpeed" -> runBackground(result, "HVAC_FAN_STEP_FAILED") {
                val delta = call.argument<Int>("delta") ?: 1
                hvacClimateController.stepFanSpeed(delta)
            }
            "setHvacFanSpeed" -> {
                val value = call.argument<Int>("fanSpeed")
                if (value == null) {
                    result.error(
                        "HVAC_FAN_SPEED_REQUIRED",
                        "setHvacFanSpeed requires fanSpeed",
                        null
                    )
                } else {
                    runBackground(result, "HVAC_FAN_SET_FAILED") {
                        hvacClimateController.setFanSpeed(value)
                    }
                }
            }
            "getTelemetryEvents" -> {
                val limit = call.argument<Int>("limit") ?: 100
                runQuery(result, "TELEMETRY_EVENTS_FAILED") {
                    telemetryRuntime.recentEventsMap(limit)
                }
            }
            "clearTelemetryDatabase" -> runBackground(result, "TELEMETRY_DATABASE_CLEAR_FAILED") {
                telemetryRuntime.clearTelemetryDatabase()
            }
            "runTelemetryRetention" -> runBackground(result, "TELEMETRY_RETENTION_FAILED") {
                telemetryRuntime.runTelemetryRetention()
            }
            "getStorageUsage" -> runQuery(result, "STORAGE_USAGE_FAILED") {
                telemetryRuntime.storageUsage()
            }
            "getTelemetrySettings" -> result.success(telemetryRuntime.settingsMap())
            "startDevicePairing" -> runBackground(result, "DEVICE_PAIRING_START_FAILED") {
                kotlinx.coroutines.runBlocking { telemetryRuntime.startDevicePairing() }
            }
            "getDevicePairingState" -> runBackground(result, "DEVICE_PAIRING_POLL_FAILED") {
                kotlinx.coroutines.runBlocking { telemetryRuntime.getDevicePairingState() }
            }
            "cancelDevicePairing" -> runBackground(result, "DEVICE_PAIRING_CANCEL_FAILED") {
                kotlinx.coroutines.runBlocking { telemetryRuntime.cancelDevicePairing() }
            }
            "getPairedCompanionDevices" -> result.success(telemetryRuntime.pairedCompanionDevices())
            "isBleStreamActive" -> result.success(mapOf("active" to telemetryRuntime.isBleStreamActive()))
            "getCloudSyncProgress" -> runQuery(result, "CLOUD_SYNC_PROGRESS_FAILED") {
                telemetryRuntime.cloudSyncProgress()
            }
            // Runs one cloud upload pass right now. Off the platform thread:
            // the pass blocks on the network.
            "forceCloudSync" -> runBackground(result, "CLOUD_SYNC_FORCE_FAILED") {
                telemetryRuntime.forceCloudSyncNow()
            }
            // Developer tool: marks the whole local history for upload again.
            "markCloudHistoryDirty" -> runBackground(result, "CLOUD_HISTORY_MARK_FAILED") {
                telemetryRuntime.markCloudHistoryDirty()
            }
            "revokeCompanionDevice" -> {
                val deviceId = call.argument<String>("deviceId")
                if (deviceId.isNullOrBlank()) {
                    result.error("DEVICE_ID_REQUIRED", "revokeCompanionDevice requires deviceId", null)
                } else {
                    result.success(telemetryRuntime.revokeCompanionDevice(deviceId))
                }
            }
            "setAutoStartOnBoot" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                val enabled = call.argument<Boolean>("enabled") ?: true
                telemetryRuntime.setAutoStartOnBoot(enabled)
            }
            "setKeepBluetoothOnEnabled" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                telemetryRuntime.setKeepBluetoothOnEnabled(enabled)
            }
            "setGpsEnabled" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                telemetryRuntime.setGpsEnabled(enabled)
            }
            "setContinuousModeEnabled" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                telemetryRuntime.setContinuousModeEnabled(enabled)
            }
            "setDebugEventFileEnabled" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                telemetryRuntime.setDebugEventFileEnabled(enabled)
            }
            "setTemperatureModeHelperEnabled" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                telemetryRuntime.setTemperatureModeHelperEnabled(enabled)
            }
            "setReplaceOemChargingEnabled" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                val settingsMap = telemetryRuntime.setReplaceOemChargingEnabled(enabled)
                // The setting is what opens this app on the plug, and it holds
                // without root. Only the rule that silences the factory screen
                // needs the shell, so a failure there is logged and not thrown:
                // half of the feature still works.
                IntentFirewallManager(appContext).setBlockAutoEnergy(enabled)
                settingsMap
            }
            "setExternalChargeControlEnabled" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                telemetryRuntime.setExternalChargeControlEnabled(enabled)
            }
            "getChargeControlAppStatus" -> runBackground(result, "CHARGE_CONTROL_APP_STATUS_FAILED") {
                telemetryRuntime.getChargeControlAppStatus()
            }
            "checkChargeControlAppUpdate" -> runBackground(result, "CHARGE_CONTROL_APP_CHECK_FAILED") {
                telemetryRuntime.checkChargeControlAppUpdate()
            }
            "installChargeControlApp" -> runBackground(result, "CHARGE_CONTROL_APP_INSTALL_FAILED") {
                telemetryRuntime.installChargeControlApp { progress ->
                    mainHandler.post {
                        channel.invokeMethod(
                            "chargeControlAppDownloadProgress",
                            mapOf("progress" to progress.toDouble())
                        )
                    }
                }
            }
            "launchChargeControlApp" -> runBackground(result, "CHARGE_CONTROL_APP_LAUNCH_FAILED") {
                telemetryRuntime.launchChargeControlApp()
            }
            "setChargeTargetSoc" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                val targetSoc = (call.argument<Number>("targetSoc"))?.toInt() ?: 80
                telemetryRuntime.setChargeTargetSoc(targetSoc)
            }
            "getChargeTargetSoc" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                mapOf("targetSoc" to telemetryRuntime.getChargeTargetSoc())
            }
            "getChargeControlState" -> runBackground(result, "CHARGE_CONTROL_FAILED") {
                telemetryRuntime.getChargeControlState()
            }
            "setChargingAmperage" -> runBackground(result, "CHARGE_CONTROL_FAILED") {
                val amps = (call.argument<Number>("amps"))?.toInt() ?: 16
                telemetryRuntime.setChargingAmperage(amps)
            }
            "setForceCharging" -> runBackground(result, "CHARGE_CONTROL_FAILED") {
                val force = call.argument<Boolean>("force") ?: false
                telemetryRuntime.setForceCharging(force)
            }
            "stopCharging" -> runBackground(result, "CHARGE_CONTROL_FAILED") {
                telemetryRuntime.stopCharging()
            }
            "setProjectionBetaEnabled" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                // The beta switch itself lives in Flutter, but the boot-time
                // sync in TelemetryCollectorService has no access to it. Record
                // it here so the setting survives a restart.
                TelemetrySettings(appContext).setProjectionBetaEnabled(enabled)
                // The same switch decides whether anything watches for a
                // phone while this app is closed. Off means off: an untouched
                // monitor never binds the OEM services.
                ProjectionAutoOpenSupervisor.get(appContext).setEnabled(enabled)
                // Ensure the device IFW is clean of projection rules
                val ok = IntentFirewallManager(appContext).cleanProjectionRules()
                mapOf("ok" to ok)
            }
            // Where the app must open, when something outside it — today the
            // charge plug — asked for a screen before Flutter was listening.
            "takePendingDestination" -> result.success(
                mapOf("destination" to takePendingDestination())
            )
            "setDefaultChargeCostPerKwh" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                telemetryRuntime.setDefaultChargeCostPerKwh(call.argument<Double>("value"))
            }
            "setPackCapacityWh" -> runBackground(result, "TELEMETRY_SETTINGS_FAILED") {
                telemetryRuntime.setPackCapacityWh(call.argument<Double>("value"))
            }
            "applyDefaultChargeCostToUnpriced" -> runBackground(result, "CHARGE_COST_APPLY_FAILED") {
                val outcome = telemetryRuntime.applyDefaultChargeCostToUnpriced()
                mapOf(
                    "ok" to outcome.ok,
                    "updatedRows" to outcome.updatedRows,
                    "costPerKwh" to outcome.costPerKwh,
                    "currency" to outcome.currency,
                    "error" to outcome.error,
                )
            }
            else -> result.notImplemented()
        }
    }

    /** Mutating call: ordered against every other mutating call. */
    private fun runBackground(
        result: MethodChannel.Result,
        errorCode: String,
        block: () -> Any?
    ) = dispatch(commandExecutor, result, errorCode, block)

    /** Read-only call: may run concurrently with any other read. */
    private fun runQuery(
        result: MethodChannel.Result,
        errorCode: String,
        block: () -> Any?
    ) = dispatch(queryExecutor, result, errorCode, block)

    private fun dispatch(
        executor: java.util.concurrent.Executor,
        result: MethodChannel.Result,
        errorCode: String,
        block: () -> Any?
    ) {
        executor.execute {
            runCatching(block).onSuccess { value ->
                mainHandler.post { result.success(value) }
            }.onFailure { error ->
                mainHandler.post {
                    result.error(
                        errorCode,
                        error.message ?: error::class.java.simpleName,
                        null
                    )
                }
            }
        }
    }

    /**
     * Records a destination asked for from outside the app, and pushes it.
     *
     * Both halves are needed and neither is enough. On a warm start Flutter is
     * already listening, so the push arrives. On a cold start this runs while
     * `main()` has not executed yet, so nothing is listening and the push is
     * lost — the shell reads [takePendingDestination] once it is up instead.
     */
    fun onDestinationRequested(destination: String) {
        pendingDestination = destination
        mainHandler.post {
            channel.invokeMethod("navigateTo", mapOf("destination" to destination))
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        vehicleSpeedChannel.setStreamHandler(null)
        telemetryRuntime.vehicleSpeedPublisher.detach()
        sensorLabChannel.setStreamHandler(null)
        sensorLabStreamer.dispose()
        helper.disconnect()
        commandExecutor.shutdownNow()
        queryExecutor.shutdownNow()
    }

    companion object {
        const val CHANNEL_NAME = "com.timhss.capyenergy/telemetry"
        const val LIVE_CHANNEL_NAME = "com.timhss.capyenergy/telemetry/live"
        const val VEHICLE_SPEED_CHANNEL_NAME =
            "com.timhss.capyenergy/telemetry/vehicle-speed"
        const val SENSOR_LAB_CHANNEL_NAME = "com.timhss.capyenergy/sensors/live"

        /** The intent extra a launcher outside the app states a screen with. */
        const val EXTRA_DESTINATION = "destination"

        /**
         * The destination waiting for Flutter to ask for it, held on the
         * companion rather than the instance: a cold start creates the bridge
         * after the intent has already been read, and the launch must not be
         * lost to that ordering.
         */
        @Volatile
        private var pendingDestination: String? = null

        /** Returns the pending destination and clears it, so it opens once. */
        @Synchronized
        fun takePendingDestination(): String? {
            val destination = pendingDestination
            pendingDestination = null
            return destination
        }

        /**
         * Enough for a screen's opening fan-out (list + settings + a deferred
         * secondary query) without letting the UI spawn unbounded database
         * work; the repositories serialize per-table access behind this anyway.
         */
        private const val QUERY_THREADS = 3
    }
}
