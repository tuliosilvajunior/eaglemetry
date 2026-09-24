package com.timhss.capyenergy.telemetry

/**
 * The one rule two replicas use when two rows name one annotation.
 *
 * Last writer wins per field group: millis -> counter -> device_id
 * lexicographic. The general rule is device_id-only; the `auto_name*` group
 * specifically uses car > phone > cloud origin rank (per ADR 0009) via
 * `shouldReplaceWithOriginRank`. The Dart copy of the general rule is
 * `annotationShouldReplace` in `packages/telemetry_core/lib/sync_annotations.dart`;
 * the two are pinned against one set of rows by the annotation convergence fixture.
 */
object AnnotationConvergence {
    const val ORIGIN_CAR = "car"
    const val ORIGIN_PHONE = "phone"
    const val ORIGIN_CLOUD = "cloud"

    /**
     * The standing order for a tie. The car ranks highest: a person editing
     * in the car and a stale phone edit landing on the same millisecond have
     * no clock to separate them, and the car is where the vehicle lives.
     */
    fun originRank(origin: String?): Int = when (origin) {
        ORIGIN_CAR -> 2
        ORIGIN_PHONE -> 1
        else -> 0
    }

    fun shouldReplace(
        existingHlcMillis: Long,
        existingHlcCounter: Int,
        existingHlcDeviceId: String,
        existingOrigin: String?,
        incomingHlcMillis: Long,
        incomingHlcCounter: Int,
        incomingHlcDeviceId: String,
        incomingOrigin: String?
    ): Boolean {
        if (incomingHlcMillis != existingHlcMillis) {
            return incomingHlcMillis > existingHlcMillis
        }
        if (incomingHlcCounter != existingHlcCounter) {
            return incomingHlcCounter > existingHlcCounter
        }
        if (incomingHlcDeviceId != existingHlcDeviceId) {
            return incomingHlcDeviceId > existingHlcDeviceId
        }
        return true
    }

    fun shouldReplace(
        existingHlc: AnnotationHlc,
        existingOrigin: String?,
        incomingHlc: AnnotationHlc,
        incomingOrigin: String?
    ): Boolean = shouldReplace(
        existingHlcMillis = existingHlc.millis,
        existingHlcCounter = existingHlc.counter,
        existingHlcDeviceId = existingHlc.deviceId,
        existingOrigin = existingOrigin,
        incomingHlcMillis = incomingHlc.millis,
        incomingHlcCounter = incomingHlc.counter,
        incomingHlcDeviceId = incomingHlc.deviceId,
        incomingOrigin = incomingOrigin
    )
    @JvmName("shouldReplaceWallDerived")
    fun shouldReplace(
        existingUpdatedAtUtcMillis: Long,
        existingOrigin: String?,
        incomingUpdatedAtUtcMillis: Long,
        incomingOrigin: String?
    ): Boolean = shouldReplace(
        existingHlcMillis = existingUpdatedAtUtcMillis,
        existingHlcCounter = 0,
        existingHlcDeviceId = existingOrigin ?: "",
        existingOrigin = existingOrigin,
        incomingHlcMillis = incomingUpdatedAtUtcMillis,
        incomingHlcCounter = 0,
        incomingHlcDeviceId = incomingOrigin ?: "",
        incomingOrigin = incomingOrigin
    )

    /**
     * ADR 0009: auto_name suggestion sync uses origin rank (car > phone > cloud)
     * as tie-break. Distinct from the general device_id-only rule after H-1.
     * Used only for the insight_places auto_name field group.
     */
    fun shouldReplaceWithOriginRank(
        existingHlcMillis: Long,
        existingHlcCounter: Int,
        existingHlcDeviceId: String,
        existingOrigin: String?,
        incomingHlcMillis: Long,
        incomingHlcCounter: Int,
        incomingHlcDeviceId: String,
        incomingOrigin: String?
    ): Boolean {
        if (incomingHlcMillis != existingHlcMillis) {
            return incomingHlcMillis > existingHlcMillis
        }
        if (incomingHlcCounter != existingHlcCounter) {
            return incomingHlcCounter > existingHlcCounter
        }
        val incomingRank = originRank(incomingOrigin)
        val existingRank = originRank(existingOrigin)
        if (incomingRank != existingRank) {
            return incomingRank > existingRank
        }
        if (incomingHlcDeviceId != existingHlcDeviceId) {
            return incomingHlcDeviceId > existingHlcDeviceId
        }
        return true
    }

    fun shouldReplaceWithOriginRank(
        existingHlc: AnnotationHlc,
        existingOrigin: String?,
        incomingHlc: AnnotationHlc,
        incomingOrigin: String?
    ): Boolean = shouldReplaceWithOriginRank(
        existingHlcMillis = existingHlc.millis,
        existingHlcCounter = existingHlc.counter,
        existingHlcDeviceId = existingHlc.deviceId,
        existingOrigin = existingOrigin,
        incomingHlcMillis = incomingHlc.millis,
        incomingHlcCounter = incomingHlc.counter,
        incomingHlcDeviceId = incomingHlc.deviceId,
        incomingOrigin = incomingOrigin
    )

    @Deprecated("Use HLC overload; wall-clock comparison is retired in 6b")
    fun shouldReplaceWallClock(
        existingUpdatedAtUtcMillis: Long,
        existingOrigin: String?,
        incomingUpdatedAtUtcMillis: Long,
        incomingOrigin: String?
    ): Boolean {
        if (incomingUpdatedAtUtcMillis != existingUpdatedAtUtcMillis) {
            return incomingUpdatedAtUtcMillis > existingUpdatedAtUtcMillis
        }
        return originRank(incomingOrigin) >= originRank(existingOrigin)
    }
    fun updatedAtUtcMillis(row: Map<String, Any?>): Long? =
        (row["updatedAtUtcMillis"] as? Number)?.toLong()

    fun origin(row: Map<String, Any?>): String? = row["origin"] as? String
}
