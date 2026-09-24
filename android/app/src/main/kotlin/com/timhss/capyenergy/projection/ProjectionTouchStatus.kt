package com.timhss.capyenergy.projection

/** What one stack's touch path is doing. One snapshot, all of it consistent. */
data class ProjectionTouchStackStatus(
    /** The OEM session service resolves on this device. */
    val available: Boolean,
    val bound: Boolean,
    /** The geometry the caller says it maps into. 0 until it says so. */
    val bufferWidth: Int,
    val bufferHeight: Int,
    /** A finger is down as far as this side knows. */
    val gestureActive: Boolean,
    /** The correction being applied. Identity until a reader calibrates one. */
    val calibration: ProjectionTouchCalibration,
    val sentCount: Int,
    val droppedCount: Int,
    /** Why the last touch was refused. Machine-readable; Dart maps it to copy. */
    val lastDropReason: String?,
    /** A binding or binder fault, never a per-touch refusal. */
    val lastError: String?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "available" to available,
        "bound" to bound,
        "bufferWidth" to bufferWidth,
        "bufferHeight" to bufferHeight,
        "gestureActive" to gestureActive,
        "calibration" to calibration.toMap(),
        "sentCount" to sentCount,
        "droppedCount" to droppedCount,
        "lastDropReason" to lastDropReason,
        "lastError" to lastError,
    )
}

/** Both stacks together, which is what the bridge publishes. */
data class ProjectionTouchStatus(
    val carplay: ProjectionTouchStackStatus,
    val androidAuto: ProjectionTouchStackStatus,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        ProjectionStack.CARPLAY.wireName to carplay.toMap(),
        ProjectionStack.ANDROID_AUTO.wireName to androidAuto.toMap(),
    )
}
