package com.timhss.capyenergy.telemetry

import android.content.Context
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.telemetry.db.JourneyEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import java.util.concurrent.Callable

/**
 * The named journeys: one row per real-world event, a window over time.
 *
 * The membership model is the time window: this table holds no member list and no exclusions, and no read
 * of it consults a second table to know what is inside. Which sessions belong
 * is computed when the group is read.
 *
 * A journey is an annotation: written after the fact, editable forever,
 * deleted by tombstone, converged by [AnnotationConvergence] with every other
 * replica of the annotation channel.
 */
class JourneyRepository(
    context: Context,
    private val clock: () -> Long = System::currentTimeMillis,
    private val annotationChanges: AnnotationChangeBroadcaster? = null,
    private val hlcClock: AnnotationHlcClock = AnnotationHlcClock.global,
    private val accountIdProvider: () -> String? = { null },
) {
    private val database = TelemetryDatabase.get(context.applicationContext)
    private val journeyDao = database.journeyDao()
    private val dbExecutor = namedSingleThreadExecutor("journeys-db")

    /** The live journeys, for readers. Tombstones stay out of the UI. */
    fun journeys(): List<JourneyEntity> =
        dbExecutor.submit(Callable { journeyDao.all() }).get()

    /** Every row the annotation channel needs, tombstones included. */
    fun journeysForSync(): List<JourneyEntity> =
        dbExecutor.submit(Callable { journeyDao.allIncludingDeleted() }).get()
    fun save(
        id: String?,
        name: String,
        startedAtUtcMillis: Long,
        endedAtUtcMillis: Long,
        note: String?,
    ): JourneyEntity {
        val trimmed = name.trim()
        require(trimmed.isNotEmpty()) { "saveJourney requires a name" }
        require(endedAtUtcMillis >= startedAtUtcMillis) {
            "saveJourney requires an end at or after its start"
        }
        val cleanedNote = note?.trim()?.takeIf { it.isNotEmpty() }
        return dbExecutor.submit(Callable {
            val now = clock()
            val hlc = hlcClock.tickAt(now)
            val existing = id?.takeIf { it.isNotBlank() }?.let(journeyDao::findById)
            val row = JourneyEntity(
                id = existing?.id ?: java.util.UUID.randomUUID().toString(),
                name = trimmed,
                startedAtUtcMillis = startedAtUtcMillis,
                endedAtUtcMillis = endedAtUtcMillis,
                note = cleanedNote,
                createdAtUtcMillis = existing?.createdAtUtcMillis ?: now,
                updatedAtUtcMillis = now,
                accountId = existing?.accountId ?: accountIdProvider(),
                origin = AnnotationConvergence.ORIGIN_CAR,
                deletedAtUtcMillis = null,
                hlcMillis = hlc.millis,
                hlcCounter = hlc.counter,
                hlcDeviceId = hlc.deviceId
            )
            journeyDao.upsert(row)
            annotationChanges?.journeysChanged()
            row
        }).get()
    }


    /**
     * The annotation delete: a tombstone, never a physical removal. A stale
     * replica that never sees the deletion would resurrect the journey on the
     * next sync otherwise. A journey that is already dead stays dead with its
     * first stamp.
     */
    fun delete(id: String) {
        require(id.isNotBlank()) { "deleteJourney requires an id" }
        dbExecutor.submit<Unit> {
            val now = clock()
            val existing = journeyDao.findById(id)
            if (existing != null && !existing.isDeleted) {
                val hlc = hlcClock.tickAt(now)
                journeyDao.upsert(
                    existing.copy(
                        deletedAtUtcMillis = now,
                        updatedAtUtcMillis = now,
                        origin = AnnotationConvergence.ORIGIN_CAR,
                        hlcMillis = hlc.millis,
                        hlcCounter = hlc.counter,
                        hlcDeviceId = hlc.deviceId
                    )
                )
                annotationChanges?.journeysChanged()
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
        if (name.isEmpty()) return false
        val startedAtUtcMillis = (row["startedAtUtcMillis"] as? Number)?.toLong() ?: return false
        val endedAtUtcMillis = (row["endedAtUtcMillis"] as? Number)?.toLong() ?: return false
        if (endedAtUtcMillis < startedAtUtcMillis) return false
        val updatedAtUtcMillis = AnnotationConvergence.updatedAtUtcMillis(row) ?: return false
        val origin = AnnotationConvergence.origin(row) ?: AnnotationConvergence.ORIGIN_PHONE
        val incomingHlc = AnnotationHlc.fromRow(row)
            ?: AnnotationHlc(millis = updatedAtUtcMillis, counter = 0, deviceId = origin)

        return dbExecutor.submit(Callable {
            hlcClock.merge(incomingHlc)
            val existing = journeyDao.findById(id)
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
            val createdAt = (row["createdAtUtcMillis"] as? Number)?.toLong()
            val merged = JourneyEntity(
                id = id,
                name = name,
                startedAtUtcMillis = startedAtUtcMillis,
                endedAtUtcMillis = endedAtUtcMillis,
                note = (row["note"] as? String)?.trim()?.takeIf { it.isNotEmpty() },
                createdAtUtcMillis = createdAt ?: existing?.createdAtUtcMillis ?: updatedAtUtcMillis,
                updatedAtUtcMillis = updatedAtUtcMillis,
                accountId = row["accountId"] as? String,
                origin = origin,
                deletedAtUtcMillis = (row["deletedAtUtcMillis"] as? Number)?.toLong(),
                hlcMillis = incomingHlc.millis,
                hlcCounter = incomingHlc.counter,
                hlcDeviceId = incomingHlc.deviceId
            )
            journeyDao.upsert(merged)
            annotationChanges?.journeysChanged()
            true
        }).get()
    }
}
