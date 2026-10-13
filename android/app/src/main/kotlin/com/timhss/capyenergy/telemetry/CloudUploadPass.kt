package com.timhss.capyenergy.telemetry

import android.util.Log

private const val TAG = "TelemetryRuntime"

/** Failure and retry policy are independent: permanent errors still fail the pass. */
internal data class CloudUploadPass(
    val telemetryMoved: Int,
    val annotationsMoved: Int,
    val retrySoon: Boolean,
    val failed: Boolean,
) {
    fun forceSyncResult(): Map<String, Any?> = mapOf(
        "cloudReady" to true,
        "paired" to true,
        "movedRows" to (telemetryMoved + annotationsMoved),
        "failed" to failed,
    )
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
    var telemetryMoved = 0
    try {
        telemetryMoved = uploadTelemetry()
    } catch (e: com.timhss.capyenergy.telemetry.sync.TelemetryCloudUploadException) {
        failed = true
        if (e.retryable) {
            Log.w(TAG, "Cloud upload transient failure for ${e.table}, will retry", e)
            retrySoon = true
        } else {
            Log.w(TAG, "Cloud upload permanent failure for ${e.table}, not retrying", e)
            handlePermanentUploadFailure(e)
        }
    } catch (e: Exception) {
        failed = true
        Log.w(TAG, "Cloud upload failed", e)
        retrySoon = true
    }
    var annotationsMoved = 0
    try {
        annotationsMoved = uploadAnnotations()
    } catch (e: com.timhss.capyenergy.telemetry.sync.AnnotationCloudUploadException) {
        failed = true
        if (e.retryable) {
            Log.w(TAG, "Annotation cloud upload transient failure for ${e.table}, will retry", e)
            retrySoon = true
        } else {
            Log.w(TAG, "Annotation cloud upload permanent failure for ${e.table}, not retrying", e)
            handlePermanentUploadFailure(e)
        }
    } catch (e: Exception) {
        failed = true
        Log.w(TAG, "Annotation cloud upload failed", e)
        retrySoon = true
    }
    try {
        syncPreferences()
    } catch (e: com.timhss.capyenergy.telemetry.control.PreferenceControlCloudException) {
        failed = true
        if (e.retryable) {
            Log.w(TAG, "Preference control sync transient failure, will retry", e)
            retrySoon = true
        } else {
            Log.w(TAG, "Preference control sync permanent failure, not retrying", e)
            handlePermanentUploadFailure(e)
        }
    } catch (e: Exception) {
        failed = true
        Log.w(TAG, "Preference control sync failed", e)
        retrySoon = true
    }
    // A permanent failure must not advertise a successful direct upload.
    if (!failed) {
        try {
            updateReadiness()
        } catch (e: Exception) {
            failed = true
            retrySoon = com.timhss.capyenergy.telemetry.sync.TelemetryCloudUploadException.isRetryable(e)
            Log.w(TAG, "Cutover readiness update failed", e)
            if (!retrySoon) handlePermanentUploadFailure(e)
        }
    }
    return CloudUploadPass(telemetryMoved, annotationsMoved, retrySoon, failed)
}

