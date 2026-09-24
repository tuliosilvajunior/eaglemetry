package com.timhss.capyenergy.carplay

data class CarplayStatus(
    /** `com.njda.carplay`'s exfeature service resolves on this device. */
    val available: Boolean,
    val bound: Boolean,
    val attached: Boolean,
    val activityResumed: Boolean,
    val dartActive: Boolean,
    /** Flutter texture id, or null before the SurfaceTexture exists. */
    val textureId: Long?,
    val bufferWidth: Int,
    val bufferHeight: Int,
    val attachCount: Int,
    /** Machine-readable code, never a localized string. Dart maps it to copy. */
    val lastError: String?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "available" to available,
        "bound" to bound,
        "attached" to attached,
        "activityResumed" to activityResumed,
        "dartActive" to dartActive,
        "textureId" to textureId,
        "bufferWidth" to bufferWidth,
        "bufferHeight" to bufferHeight,
        "attachCount" to attachCount,
        "lastError" to lastError,
    )
}
