package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.db.InsightPlaceDao
import com.timhss.capyenergy.telemetry.db.JourneyDao
import com.timhss.capyenergy.telemetry.db.PreferenceDao
import com.timhss.capyenergy.telemetry.db.SessionCostDao
import com.timhss.capyenergy.telemetry.db.SessionDao

/**
 * Car-side cloud uploader for annotation tables (Phase 2 Lane B Step 4).
 *
 * Mirrors [TelemetryCloudUploader]'s shape: reads local rows and calls
 * [CloudSink.upsert] pointed at the four annotation tables. Every local write
 * already carries a single-row HLC stamp ([com.timhss.capyenergy.telemetry.AnnotationHlc]);
 * the cloud expects per-field-group triples, so this uploader fans that one
 * stamp to every group on the table (full row, not just the changed one),
 * otherwise the Postgres per-group merge trigger would treat every unlisted
 * group as regressed to zero.
 *
 * Durability choice: annotations are low-volume (tens of rows, not thousands
 * per minute), so no new `dirty` migration is added. Each scheduled sync pass
 * uploads the full set of local annotation rows (fire-and-forget, retried on
 * next pass if it fails). A write made while offline therefore still reaches
 * the cloud once connectivity returns — the minimum bar — without adding
 * per-annotation dirty tracking that would duplicate Phase 0's measurement
 * machinery for a workload that does not need it. If volume ever grows,
 * a dirty column can be added without changing the wire shape.
 *
 * Conflict columns match the cloud primary keys:
 *   insight_places (account_id, id)
 *   journeys       (account_id, id)
 *   session_costs  (vehicle_id, session_id)
 *   preferences    (account_id, scope, key)
 */
data class AnnotationCloudUploadReport(
    val perStream: Map<String, Int> = emptyMap()
) {
    val total: Int get() = perStream.values.sum()
    val movedNothing: Boolean get() = total == 0
}

class AnnotationCloudUploadException(
    val table: String,
    cause: Throwable,
    val retryable: Boolean = true
) : Exception("Annotation cloud upload failed for $table: ${cause.message}", cause) {
    companion object {
        fun isRetryable(error: Throwable): Boolean {
            var cur: Throwable? = error
            while (cur != null) {
                val msg = (cur.message ?: "").lowercase()
                if (msg.contains("401") || msg.contains("403")) return false
                if (msg.contains("409") || msg.contains("422")) return false
                if (msg.contains("constraint") || msg.contains("violates")) return false
                if (msg.contains("unique constraint") || msg.contains("foreign key")) return false
                cur = cur.cause
            }
            var c: Throwable? = error
            while (c != null) {
                val name = c.javaClass.simpleName.lowercase()
                if (name.contains("timeout") || name.contains("interrupted")) return true
                c = c.cause
            }
            return true
        }
    }
}

class AnnotationCloudUploader(
    private val insightPlaceDao: InsightPlaceDao,
    private val sessionCostDao: SessionCostDao,
    private val journeyDao: JourneyDao,
    private val preferenceDao: PreferenceDao,
    private val sessionDao: SessionDao,
    private val sink: CloudSink,
    private val vehicleIdProvider: () -> String?,
    private val accountIdProvider: () -> String?,
    private val aliases: com.timhss.capyenergy.telemetry.VehicleIdAliasStore? = null,
    private val chunkSize: Int = 100
) {
    companion object {
        const val INSIGHT_PLACES_TABLE = "insight_places"
        const val SESSION_COSTS_TABLE = "session_costs"
        const val JOURNEYS_TABLE = "journeys"
        const val PREFERENCES_TABLE = "preferences"

        val INSIGHT_PLACES_CONFLICT = listOf("account_id", "id")
        val JOURNEYS_CONFLICT = listOf("account_id", "id")
        val SESSION_COSTS_CONFLICT = listOf("vehicle_id", "session_id")
        val PREFERENCES_CONFLICT = listOf("account_id", "scope", "key")

        private const val UNASSIGNED = "unassigned"
    }

    suspend fun upload(): AnnotationCloudUploadReport {
        val accountId = accountIdProvider() ?: return AnnotationCloudUploadReport()
        val globalVehicleId = vehicleIdProvider()
            ?.takeIf { it.isNotBlank() && it != UNASSIGNED }
            ?.let { aliases?.canonicalFor(it)?.takeIf { a -> a.isNotBlank() } ?: it }

        fun canonical(id: String): String {
            if (id.isBlank() || id == UNASSIGNED) return globalVehicleId ?: id
            val found = aliases?.canonicalFor(id)?.takeIf { it.isNotBlank() }
            if (found != null) return found
            if (globalVehicleId != null && globalVehicleId != id) {
                aliases?.record(id, globalVehicleId, System.currentTimeMillis())
                return globalVehicleId
            }
            return id
        }

        val perStream = mutableMapOf<String, Int>()
        var firstFailure: AnnotationCloudUploadException? = null

        // --- insight_places -------------------------------------------------
        try {
            val places = insightPlaceDao.allIncludingDeleted()
            if (places.isNotEmpty()) {
                for (chunk in places.chunked(chunkSize)) {
                    val rows = chunk.map { place ->
                        val effectiveAccountId = place.accountId?.takeIf { it.isNotBlank() } ?: accountId
                        mapOf(
                            "id" to place.id,
                            "account_id" to effectiveAccountId,
                            "name" to place.name,
                            "latitude" to place.latitude,
                            "longitude" to place.longitude,
                            "radius_m" to place.radiusM,
                            "created_at_utc_millis" to place.createdAtUtcMillis,
                            "updated_at_utc_millis" to place.updatedAtUtcMillis,
                            "origin" to place.origin,
                            "deleted_at_utc_millis" to place.deletedAtUtcMillis,
                            "auto_name" to place.autoName,
                            "auto_name_updated_at_utc_millis" to place.autoNameUpdatedAtUtcMillis,
                            "auto_name_source" to place.autoNameSource,
                            "name_hlc_millis" to place.hlcMillis,
                            "name_hlc_counter" to place.hlcCounter,
                            "name_hlc_device_id" to place.hlcDeviceId,
                            "geofence_hlc_millis" to place.hlcMillis,
                            "geofence_hlc_counter" to place.hlcCounter,
                            "geofence_hlc_device_id" to place.hlcDeviceId,
                            "auto_name_hlc_millis" to place.hlcMillis,
                            "auto_name_hlc_counter" to place.hlcCounter,
                            "auto_name_hlc_device_id" to place.hlcDeviceId
                        )
                    }
                    try {
                        sink.upsert(INSIGHT_PLACES_TABLE, rows, INSIGHT_PLACES_CONFLICT, merge = true)
                    } catch (e: Exception) {
                        throw AnnotationCloudUploadException(
                            INSIGHT_PLACES_TABLE, e, retryable = AnnotationCloudUploadException.isRetryable(e)
                        )
                    }
                    perStream[INSIGHT_PLACES_TABLE] = (perStream[INSIGHT_PLACES_TABLE] ?: 0) + rows.size
                }
            }
        } catch (e: AnnotationCloudUploadException) {
            if (firstFailure == null) firstFailure = e
        }

        // --- session_costs --------------------------------------------------
        try {
            val costs = sessionCostDao.all()
            if (costs.isNotEmpty()) {
                // A cost belongs to its session: with no local session there is
                // no vehicle to name it under, so it is not uploaded (the cloud
                // binds the row to the token's vehicle). A pending session's cost
                // waits with it — the session's own stamps are not final yet. The
                // row stays local either way; nothing is deleted here.
                val scoped = try {
                    costs.mapNotNull { cost ->
                        val session = sessionDao.findById(cost.sessionId)
                        val vehicleId = session?.vehicleId
                        if (session == null || vehicleId == null || vehicleId == UNASSIGNED || vehicleId.isBlank() || session.timeState == "pending") null
                        else cost to canonical(vehicleId)
                    }
                } catch (e: Exception) {
                    throw AnnotationCloudUploadException(
                        SESSION_COSTS_TABLE, e, retryable = AnnotationCloudUploadException.isRetryable(e),
                    )
                }
                for (chunk in scoped.chunked(chunkSize)) {
                    val rows = chunk.map { (cost, vehicleId) ->
                        mapOf(
                            "vehicle_id" to vehicleId,
                            "session_id" to cost.sessionId,
                            "account_id" to accountId,
                            "cost_per_kwh" to cost.costPerKwh,
                            "paid_amount" to cost.paidAmount,
                            "cost_currency" to cost.costCurrency,
                            "updated_at_utc_millis" to cost.updatedAtUtcMillis,
                            "origin" to cost.origin,
                            "cost_hlc_millis" to cost.hlcMillis,
                            "cost_hlc_counter" to cost.hlcCounter,
                            "cost_hlc_device_id" to cost.hlcDeviceId
                        )
                    }
                    try {
                        sink.upsert(SESSION_COSTS_TABLE, rows, SESSION_COSTS_CONFLICT, merge = true)
                    } catch (e: Exception) {
                        throw AnnotationCloudUploadException(
                            SESSION_COSTS_TABLE, e, retryable = AnnotationCloudUploadException.isRetryable(e)
                        )
                    }
                    perStream[SESSION_COSTS_TABLE] = (perStream[SESSION_COSTS_TABLE] ?: 0) + rows.size
                }
            }
        } catch (e: AnnotationCloudUploadException) {
            if (firstFailure == null) firstFailure = e
        }

        // --- journeys -------------------------------------------------------
        try {
            val journeys = journeyDao.allIncludingDeleted()
            if (journeys.isNotEmpty()) {
                for (chunk in journeys.chunked(chunkSize)) {
                    val rows = chunk.map { journey ->
                        val effectiveAccountId = journey.accountId?.takeIf { it.isNotBlank() } ?: accountId
                        mapOf(
                            "id" to journey.id,
                            "account_id" to effectiveAccountId,
                            "name" to journey.name,
                            "started_at_utc_millis" to journey.startedAtUtcMillis,
                            "ended_at_utc_millis" to journey.endedAtUtcMillis,
                            "note" to journey.note,
                            "created_at_utc_millis" to journey.createdAtUtcMillis,
                            "updated_at_utc_millis" to journey.updatedAtUtcMillis,
                            "origin" to journey.origin,
                            "deleted_at_utc_millis" to journey.deletedAtUtcMillis,
                            "name_hlc_millis" to journey.hlcMillis,
                            "name_hlc_counter" to journey.hlcCounter,
                            "name_hlc_device_id" to journey.hlcDeviceId,
                            "note_hlc_millis" to journey.hlcMillis,
                            "note_hlc_counter" to journey.hlcCounter,
                            "note_hlc_device_id" to journey.hlcDeviceId,
                            "time_range_hlc_millis" to journey.hlcMillis,
                            "time_range_hlc_counter" to journey.hlcCounter,
                            "time_range_hlc_device_id" to journey.hlcDeviceId
                        )
                    }
                    try {
                        sink.upsert(JOURNEYS_TABLE, rows, JOURNEYS_CONFLICT, merge = true)
                    } catch (e: Exception) {
                        throw AnnotationCloudUploadException(
                            JOURNEYS_TABLE, e, retryable = AnnotationCloudUploadException.isRetryable(e)
                        )
                    }
                    perStream[JOURNEYS_TABLE] = (perStream[JOURNEYS_TABLE] ?: 0) + rows.size
                }
            }
        } catch (e: AnnotationCloudUploadException) {
            if (firstFailure == null) firstFailure = e
        }

        // --- preferences ----------------------------------------------------
        try {
            val prefs = preferenceDao.syncable()
            if (prefs.isNotEmpty()) {
                for (chunk in prefs.chunked(chunkSize)) {
                    val rows = chunk.map { pref ->
                        mapOf(
                            "account_id" to accountId,
                            "scope" to pref.scope,
                            "key" to pref.key,
                            "value" to pref.value,
                            "updated_at_utc_millis" to pref.updatedAtUtcMillis,
                            "origin" to pref.origin,
                            "deleted_at_utc_millis" to pref.deletedAtUtcMillis,
                            "hlc_millis" to pref.hlcMillis,
                            "hlc_counter" to pref.hlcCounter,
                            "hlc_device_id" to pref.hlcDeviceId
                        )
                    }
                    try {
                        sink.upsert(PREFERENCES_TABLE, rows, PREFERENCES_CONFLICT, merge = true)
                    } catch (e: Exception) {
                        throw AnnotationCloudUploadException(
                            PREFERENCES_TABLE, e, retryable = AnnotationCloudUploadException.isRetryable(e)
                        )
                    }
                    perStream[PREFERENCES_TABLE] = (perStream[PREFERENCES_TABLE] ?: 0) + rows.size
                }
            }
        } catch (e: AnnotationCloudUploadException) {
            if (firstFailure == null) firstFailure = e
        }

        if (firstFailure != null) throw firstFailure
        return AnnotationCloudUploadReport(perStream)
    }
}
