package com.timhss.capyenergy.telemetry

import android.content.Context
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.telemetry.db.InsightPlaceEntity
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException

class InsightRepository(
    context: Context,
    private val clock: () -> Long = System::currentTimeMillis,
    private val annotationChanges: AnnotationChangeBroadcaster? = null,
    private val hlcClock: AnnotationHlcClock = AnnotationHlcClock.global,
    private val accountIdProvider: () -> String? = { null },
) {
    private val database = TelemetryDatabase.get(context.applicationContext)
    private val sessionDao = database.sessionDao()
    private val intervalDao = database.intervalDao()
    private val segmentDao = database.tripSegmentDao()
    private val placeDao = database.insightPlaceDao()
    private val dbExecutor = namedSingleThreadExecutor("insights-db")

    fun trips(subjectId: String?): InsightTripsPage {
        return dbExecutor.submit(Callable {
            val now = clock()
            val byId = LinkedHashMap<String, SessionEntity>()
            for (trip in sessionDao.inWindow("TRIP", 0L, now)) {
                byId[trip.id] = trip
            }
            if (!subjectId.isNullOrBlank()) {
                sessionDao.findById(subjectId)?.takeIf { it.kind == "TRIP" }?.let { byId.putIfAbsent(it.id, it) }
            }
            val trips = byId.values.toList()
            val ids = trips.map { it.id }
            val withBuckets = if (ids.isEmpty()) {
                emptySet()
            } else {
                intervalDao.sessionsWithBuckets(ids).toSet()
            }
            val segments = if (ids.isEmpty()) {
                emptyMap()
            } else {
                segmentDao.forSessions(ids).groupBy { it.sessionId }
            }
            InsightTripsPage(
                trips = trips.map { trip ->
                    InsightTrips.row(
                        trip = trip,
                        hasMinuteBuckets = trip.id in withBuckets,
                        segments = segments[trip.id].orEmpty(),
                    )
                },
                subjectId = subjectId,
            )
        }).get()
    }

    fun places(): List<InsightPlaceRow> =
        dbExecutor.submit(Callable { placeDao.all().map { it.toRow() } }).get()

    /** Every row the annotation channel needs, tombstones included. */
    fun placesForSync(): List<InsightPlaceEntity> =
        dbExecutor.submit(Callable { placeDao.allIncludingDeleted() }).get()

    fun savePlace(
        id: String?,
        name: String,
        latitude: Double,
        longitude: Double,
        radiusM: Double,
        autoName: String? = null,
        autoNameUpdatedAtUtcMillis: Long? = null,
        autoNameSource: String? = null,
    ): InsightPlaceRow {
        val trimmed = name.trim()
        require(latitude.isFinite() && longitude.isFinite()) {
            "saveInsightPlace requires finite coordinates"
        }
        val radius = if (radiusM.isFinite() && radiusM > 0.0) radiusM else 150.0
        return submit {
            val now = clock()
            val existing = id?.takeIf { it.isNotBlank() }?.let(placeDao::findById)
            // A second place with one normalized name inside
            // PlaceDuplicateGuard.NEAR_DISTANCE_M is refused: merge instead,
            // or widen the radius. Updating the conflicting row itself is fine.
            if (trimmed.isNotEmpty()) {
                val conflict = PlaceDuplicateGuard.findConflict(
                    id = existing?.id ?: id?.takeIf { it.isNotBlank() },
                    name = trimmed,
                    latitude = latitude,
                    longitude = longitude,
                    live = placeDao.all()
                )
                require(conflict == null) {
                    PlaceDuplicateGuard.conflictMessage(
                        conflict!!.row.name.ifBlank { trimmed },
                        conflict.distanceM
                    )
                }
            }
            // Preserve existing autoName when caller does not provide one.
            val effectiveAutoName = autoName?.trim()?.takeIf { it.isNotEmpty() } ?: existing?.autoName
            require(trimmed.isNotEmpty() || (effectiveAutoName?.trim()?.isNotEmpty() == true)) {
                "saveInsightPlace requires a name or autoName"
            }
            val effectiveAutoNameUpdatedAt = when {
                autoNameUpdatedAtUtcMillis != null -> autoNameUpdatedAtUtcMillis
                autoName != null && autoName.trim().isNotEmpty() -> now
                else -> existing?.autoNameUpdatedAtUtcMillis
            }
            val effectiveAutoNameSource = autoNameSource ?: existing?.autoNameSource
            val hlc = hlcClock.tick()
            val row = InsightPlaceEntity(
                id = existing?.id ?: java.util.UUID.randomUUID().toString(),
                name = trimmed,
                latitude = latitude,
                longitude = longitude,
                radiusM = radius,
                createdAtUtcMillis = existing?.createdAtUtcMillis ?: now,
                updatedAtUtcMillis = now,
                accountId = existing?.accountId ?: accountIdProvider(),
                origin = AnnotationConvergence.ORIGIN_CAR,
                deletedAtUtcMillis = null,
                autoName = effectiveAutoName,
                autoNameUpdatedAtUtcMillis = effectiveAutoNameUpdatedAt,
                autoNameSource = effectiveAutoNameSource,
                hlcMillis = hlc.millis,
                hlcCounter = hlc.counter,
                hlcDeviceId = hlc.deviceId
            )
            placeDao.upsert(row)
            annotationChanges?.placesChanged()
            row.toRow()
        }
    }

    /**
     * Runs a read-modify-write on the single insights executor and hands the
     * failure itself back, not the [ExecutionException] wrapper: the bridge
     * turns whatever lands here into the error line the UI shows, so the
     * duplicate-refusal words must survive the hop.
     */
    private fun <T> submit(block: () -> T): T =
        try {
            dbExecutor.submit(Callable { block() }).get()
        } catch (e: ExecutionException) {
            throw e.cause ?: e
        }

    /**
     * The annotation delete: a tombstone, never a physical removal. A stale
     * replica that never sees the deletion would resurrect the place on the
     * next sync otherwise. A place that is already dead stays dead with its
     * first stamp.
     */
    fun deletePlace(id: String) {
        require(id.isNotBlank()) { "deleteInsightPlace requires an id" }
        dbExecutor.submit<Unit> {
            val now = clock()
            val existing = placeDao.findById(id)
            if (existing != null && !existing.isDeleted) {
                val hlc = hlcClock.tick()
                placeDao.upsert(
                    existing.copy(
                        deletedAtUtcMillis = now,
                        updatedAtUtcMillis = now,
                        origin = AnnotationConvergence.ORIGIN_CAR,
                        hlcMillis = hlc.millis,
                        hlcCounter = hlc.counter,
                        hlcDeviceId = hlc.deviceId
                    )
                )
                annotationChanges?.placesChanged()
            }
        }.get()
    }
    /**
     * One row from the annotation channel, pushed by the phone or replayed
     * over the pull. Last writer wins, the origin breaks a millisecond tie.
     * Returns true when this replica's row moved.
     */
    fun mergeIncoming(row: Map<String, Any?>): Boolean {
        val id = (row["id"] as? String)?.takeIf { it.isNotBlank() } ?: return false
        val name = (row["name"] as? String)?.trim().orEmpty()
        val latitude = (row["latitude"] as? Number)?.toDouble() ?: return false
        val longitude = (row["longitude"] as? Number)?.toDouble() ?: return false
        if (!latitude.isFinite() || !longitude.isFinite()) return false
        val incomingAutoName = row["autoName"] as? String
        if (name.isEmpty() && (incomingAutoName == null || incomingAutoName.trim().isEmpty())) return false
        val updatedAtUtcMillis = AnnotationConvergence.updatedAtUtcMillis(row) ?: return false
        val origin = AnnotationConvergence.origin(row) ?: AnnotationConvergence.ORIGIN_PHONE
        // Extract incoming HLC if present; otherwise synthesize from wall time + origin.
        val incomingHlc = AnnotationHlc.fromRow(row)
            ?: AnnotationHlc(millis = updatedAtUtcMillis, counter = 0, deviceId = origin)

        return dbExecutor.submit(Callable {
            // Merge clock even if we judge the row stale, so future local writes
            // are causally after the remote. HLC now decides winners (6b).
            hlcClock.merge(incomingHlc)
            val existing = placeDao.findById(id)
            if (existing != null && !AnnotationConvergence.shouldReplace(
                    existingHlc = AnnotationHlc(
                        millis = existing.hlcMillis,
                        counter = existing.hlcCounter,
                        deviceId = existing.hlcDeviceId,
                    ),
                    existingOrigin = existing.origin,
                    incomingHlc = incomingHlc,
                    incomingOrigin = origin
                )
            ) {
                return@Callable false
            }
            val radius = (row["radiusM"] as? Number)?.toDouble()
            val createdAt = (row["createdAtUtcMillis"] as? Number)?.toLong()
            val merged = InsightPlaceEntity(
                id = id,
                name = name,
                latitude = latitude,
                longitude = longitude,
                radiusM = if (radius != null && radius.isFinite() && radius > 0.0) radius else 150.0,
                createdAtUtcMillis = createdAt ?: existing?.createdAtUtcMillis ?: updatedAtUtcMillis,
                updatedAtUtcMillis = updatedAtUtcMillis,
                accountId = row["accountId"] as? String,
                origin = origin,
                deletedAtUtcMillis = (row["deletedAtUtcMillis"] as? Number)?.toLong(),
                autoName = row["autoName"] as? String,
                autoNameUpdatedAtUtcMillis = (row["autoNameUpdatedAtUtcMillis"] as? Number)?.toLong()
                    ?: (row["autoNameUpdatedAt"] as? Number)?.toLong(),
                autoNameSource = row["autoNameSource"] as? String,
                hlcMillis = incomingHlc.millis,
                hlcCounter = incomingHlc.counter,
                hlcDeviceId = incomingHlc.deviceId
            )
            placeDao.upsert(merged)
            annotationChanges?.placesChanged()
            true
        }).get()
    }
}
