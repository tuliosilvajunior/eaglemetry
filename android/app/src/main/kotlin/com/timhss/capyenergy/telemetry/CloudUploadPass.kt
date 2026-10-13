package com.timhss.capyenergy.telemetry

import android.util.Log
import com.timhss.capyenergy.telemetry.sync.HttpCloudSinkException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

private const val TAG = "TelemetryRuntime"

/** Failure and retry policy are independent: permanent errors still fail the pass. */
internal data class CloudUploadPass(
    val telemetryMoved: Int,
    val annotationsMoved: Int,
    val retrySoon: Boolean,
    val failed: Boolean,
    val failureKind: CloudSyncFailureKind? = null,
) {
    fun forceSyncResult(): Map<String, Any?> = mapOf(
        "cloudReady" to true,
        "paired" to true,
        "movedRows" to (telemetryMoved + annotationsMoved),
        "failed" to failed,
        "failureKind" to failureKind?.wireValue,
    )
}

/** Safe categories for the UI; never includes provider messages or credentials. */
internal enum class CloudSyncFailureKind(val wireValue: String) {
    NETWORK("network"),
    AUTHENTICATION("authentication"),
    SERVER("server"),
    OTHER("other"),
}

internal fun classifyCloudSyncFailure(error: Throwable): CloudSyncFailureKind {
    var current: Throwable? = error
    while (current != null) {
        val status = when (current) {
            is HttpCloudSinkException -> current.statusCode
            else -> Regex("\\bHTTP\\s+(\\d{3})\\b", RegexOption.IGNORE_CASE)
                .find(current.message.orEmpty())
                ?.groupValues
                ?.getOrNull(1)
                ?.toIntOrNull()
        }
        when (status) {
            401, 403 -> return CloudSyncFailureKind.AUTHENTICATION
            408, 429 -> return CloudSyncFailureKind.SERVER
        }
        if (status != null && status in 500..599) return CloudSyncFailureKind.SERVER
        if (current is UnknownHostException ||
            current is ConnectException ||
            current is NoRouteToHostException ||
            current is SocketTimeoutException ||
            current is SocketException
        ) {
            return CloudSyncFailureKind.NETWORK
        }
        current = current.cause
    }
    return CloudSyncFailureKind.OTHER
}

// Callbacks keep the actual pass testable without constructing Android services.
internal fun runCloudUploadPass(
    uploadTelemetry: () -> Int,
    uploadAnnotations: () -> Int,
    syncPreferences: () -> Unit,
    handlePermanentUploadFailure: (Throwable) -> Unit,
    updateReadiness: () -> Unit,
): CloudUploadPass {
    var retrySoon = false
    var failed = false
    var failureKind: CloudSyncFailureKind? = null
    fun recordFailure(error: Throwable) {
        failed = true
        if (failureKind == null) failureKind = classifyCloudSyncFailure(error)
    }
    var telemetryMoved = 0
    try {
        telemetryMoved = uploadTelemetry()
    } catch (e: com.timhss.capyenergy.telemetry.sync.TelemetryCloudUploadException) {
        recordFailure(e)
        if (e.retryable) {
            Log.w(TAG, "Cloud upload transient failure for ${e.table}, will retry", e)
            retrySoon = true
        } else {
            Log.w(TAG, "Cloud upload permanent failure for ${e.table}, not retrying", e)
            handlePermanentUploadFailure(e)
        }
    } catch (e: Exception) {
        recordFailure(e)
        Log.w(TAG, "Cloud upload failed", e)
        retrySoon = true
    }
    var annotationsMoved = 0
    try {
        annotationsMoved = uploadAnnotations()
    } catch (e: com.timhss.capyenergy.telemetry.sync.AnnotationCloudUploadException) {
        recordFailure(e)
        if (e.retryable) {
            Log.w(TAG, "Annotation cloud upload transient failure for ${e.table}, will retry", e)
            retrySoon = true
        } else {
            Log.w(TAG, "Annotation cloud upload permanent failure for ${e.table}, not retrying", e)
            handlePermanentUploadFailure(e)
        }
    } catch (e: Exception) {
        recordFailure(e)
        Log.w(TAG, "Annotation cloud upload failed", e)
        retrySoon = true
    }
    try {
        syncPreferences()
    } catch (e: com.timhss.capyenergy.telemetry.control.PreferenceControlCloudException) {
        recordFailure(e)
        if (e.retryable) {
            Log.w(TAG, "Preference control sync transient failure, will retry", e)
            retrySoon = true
        } else {
            Log.w(TAG, "Preference control sync permanent failure, not retrying", e)
            handlePermanentUploadFailure(e)
        }
    } catch (e: Exception) {
        recordFailure(e)
        Log.w(TAG, "Preference control sync failed", e)
        retrySoon = true
    }
    // A permanent failure must not advertise a successful direct upload.
    if (!failed) {
        try {
            updateReadiness()
        } catch (e: Exception) {
            recordFailure(e)
            retrySoon = com.timhss.capyenergy.telemetry.sync.TelemetryCloudUploadException.isRetryable(e)
            Log.w(TAG, "Cutover readiness update failed", e)
            if (!retrySoon) handlePermanentUploadFailure(e)
        }
    }
    return CloudUploadPass(telemetryMoved, annotationsMoved, retrySoon, failed, failureKind)
}

