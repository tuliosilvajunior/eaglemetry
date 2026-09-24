package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface SessionDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(session: SessionEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertAll(sessions: List<SessionEntity>)

    @Query("SELECT * FROM session WHERE id = :id LIMIT 1")
    fun findById(id: String): SessionEntity?

    @Query(
        "SELECT * FROM session " +
            "WHERE (:kind IS NULL OR kind = :kind) " +
            "AND (:status IS NULL OR status = :status) " +
            "AND (:fromUtcMillis IS NULL OR startedAtUtcMillis >= :fromUtcMillis) " +
            "AND (:toUtcMillis IS NULL OR startedAtUtcMillis <= :toUtcMillis) " +
            "ORDER BY startedAtUtcMillis DESC, id DESC " +
            "LIMIT :limit OFFSET :offset"
    )
    fun listSessionsFiltered(
        kind: String?,
        status: String?,
        fromUtcMillis: Long?,
        toUtcMillis: Long?,
        limit: Int,
        offset: Int
    ): List<SessionEntity>

    @Query(
        "SELECT COUNT(*) FROM session " +
            "WHERE (:kind IS NULL OR kind = :kind) " +
            "AND (:status IS NULL OR status = :status) " +
            "AND (:fromUtcMillis IS NULL OR startedAtUtcMillis >= :fromUtcMillis) " +
            "AND (:toUtcMillis IS NULL OR startedAtUtcMillis <= :toUtcMillis)"
    )
    fun countSessionsFiltered(
        kind: String?,
        status: String?,
        fromUtcMillis: Long?,
        toUtcMillis: Long?
    ): Long

    /**
     * The visible session list under the local account stamp.
     *
     * A row with no account is adopted by the first account that claims the
     * car — the same `account_id IS NULL` rule the cloud's claim backfill
     * proved (PR #281/#282) — so a reader shows every unowned row plus its
     * own, and nothing of another account's. With no paired account the
     * predicate degenerates to `accountId IS NULL`, which is the pre-stamp
     * view: a car used before pairing keeps its whole history.
     */
    @Query(
        "SELECT * FROM session " +
            "WHERE ${SessionAccountVisibility.ACCOUNT_PREDICATE} " +
            "AND (:kind IS NULL OR kind = :kind) " +
            "AND (:status IS NULL OR status = :status) " +
            "AND (:fromUtcMillis IS NULL OR startedAtUtcMillis >= :fromUtcMillis) " +
            "AND (:toUtcMillis IS NULL OR startedAtUtcMillis <= :toUtcMillis) " +
            "ORDER BY startedAtUtcMillis DESC, id DESC " +
            "LIMIT :limit OFFSET :offset"
    )
    fun listSessionsSatisfyingAccount(
        accountId: String?,
        kind: String?,
        status: String?,
        fromUtcMillis: Long?,
        toUtcMillis: Long?,
        limit: Int,
        offset: Int
    ): List<SessionEntity>

    @Query(
        "SELECT COUNT(*) FROM session " +
            "WHERE ${SessionAccountVisibility.ACCOUNT_PREDICATE} " +
            "AND (:kind IS NULL OR kind = :kind) " +
            "AND (:status IS NULL OR status = :status) " +
            "AND (:fromUtcMillis IS NULL OR startedAtUtcMillis >= :fromUtcMillis) " +
            "AND (:toUtcMillis IS NULL OR startedAtUtcMillis <= :toUtcMillis)"
    )
    fun countSessionsSatisfyingAccount(
        accountId: String?,
        kind: String?,
        status: String?,
        fromUtcMillis: Long?,
        toUtcMillis: Long?
    ): Long

    @Query("SELECT * FROM session WHERE kind = :kind ORDER BY startedAtUtcMillis DESC")
    fun findByKind(kind: String): List<SessionEntity>

    /**
     * Time authority G3: a `pending` session's wall stamps are not yet
     * trustworthy, so it never enters a wall-clock window while pending. The
     * sweep resolves it and it enters automatically under its corrected stamp.
     */
    @Query(
        "SELECT * FROM session " +
            "WHERE kind = :kind " +
            "AND status != 'FINALIZATION_PENDING' " +
            "AND timeState != 'pending' " +
            "AND startedAtUtcMillis < :endUtcMillis " +
            "AND COALESCE(endedAtUtcMillis, updatedAtUtcMillis) > :startUtcMillis " +
            "ORDER BY startedAtUtcMillis DESC"
    )
    fun inWindow(kind: String, startUtcMillis: Long, endUtcMillis: Long): List<SessionEntity>

    /** Same G3 hold as [inWindow]: no pending session in a wall window. */
    @Query(
        "SELECT * FROM session " +
            "WHERE status != 'FINALIZATION_PENDING' " +
            "AND timeState != 'pending' " +
            "AND startedAtUtcMillis < :endUtcMillis " +
            "AND COALESCE(endedAtUtcMillis, updatedAtUtcMillis) > :startUtcMillis " +
            "ORDER BY startedAtUtcMillis DESC"
    )
    fun inWindowAll(startUtcMillis: Long, endUtcMillis: Long): List<SessionEntity>

    /**
     * Trips that ended inside [startUtcMillis, endUtcMillis].
     * Range efficiency window. Same G3 hold: pending never qualifies.
     */
    @Query(
        "SELECT * FROM session " +
            "WHERE kind = 'TRIP' " +
            "AND status != 'FINALIZATION_PENDING' " +
            "AND timeState != 'pending' " +
            "AND endedAtUtcMillis IS NOT NULL " +
            "AND endedAtUtcMillis >= :startUtcMillis " +
            "AND endedAtUtcMillis <= :endUtcMillis " +
            "ORDER BY endedAtUtcMillis DESC"
    )
    fun rangeWindow(startUtcMillis: Long, endUtcMillis: Long): List<SessionEntity>

    @Query(
        "SELECT * FROM session " +
            "WHERE kind = :kind " +
            "AND status != 'FINALIZATION_PENDING' " +
            "ORDER BY startedAtUtcMillis DESC, updatedAtUtcMillis DESC LIMIT :limit"
    )
    fun latest(kind: String, limit: Int): List<SessionEntity>

    @Query(
        "SELECT * FROM session " +
            "WHERE status != 'FINALIZATION_PENDING' " +
            "ORDER BY startedAtUtcMillis DESC, updatedAtUtcMillis DESC LIMIT :limit"
    )
    fun latestAll(limit: Int): List<SessionEntity>

    @Query("SELECT COUNT(*) FROM session WHERE kind = :kind AND status != 'FINALIZATION_PENDING'")
    fun countListed(kind: String): Long

    @Query("SELECT COUNT(*) FROM session WHERE status != 'FINALIZATION_PENDING'")
    fun countListedAll(): Long

    @Query(
        "SELECT * FROM session " +
            "WHERE kind = :kind " +
            "AND endedAtUtcMillis IS NULL " +
            "AND status NOT IN ('ENDED', 'DISCONNECTED') " +
            "ORDER BY updatedAtUtcMillis DESC, startedAtUtcMillis DESC LIMIT 1"
    )
    fun latestOpen(kind: String): SessionEntity?

    @Query(
        "UPDATE session SET " +
            "endedAtUtcMillis = :endedAtUtcMillis, " +
            "endedAtElapsedNanos = :endedAtElapsedNanos, " +
            "status = 'ENDED', " +
            "endReason = :reason, " +
            "updatedAtUtcMillis = :updatedAtUtcMillis " +
            "WHERE kind = :kind " +
            "AND endedAtUtcMillis IS NULL " +
            "AND status NOT IN ('ENDED', 'DISCONNECTED')"
    )
    fun closeOpenSessions(kind: String, endedAtUtcMillis: Long, endedAtElapsedNanos: Long, reason: String, updatedAtUtcMillis: Long): Int

    @Query("SELECT COUNT(*) FROM session")
    fun count(): Long

    @Query("SELECT COUNT(*) FROM session WHERE kind = :kind")
    fun countByKind(kind: String): Long

    @Query(
        "SELECT * FROM session WHERE status = 'FINALIZATION_PENDING' " +
            "ORDER BY updatedAtUtcMillis ASC"
    )
    fun pendingFinalization(): List<SessionEntity>

    /**
     * `CONTINUOUS` is excluded: it is not one of the sessions/intervals sync
     * streams filter by kind, without an explicit exclusion the companion's
     * interval volume would roughly double. Issue 199.
     */
    @Query(
        "SELECT * FROM session " +
            "WHERE endedAtUtcMillis IS NOT NULL " +
            "AND status != 'FINALIZATION_PENDING' " +
            "AND kind != 'CONTINUOUS' " +
            "AND (startedAtUtcMillis > :afterStartedAtUtcMillis " +
            "OR (startedAtUtcMillis = :afterStartedAtUtcMillis AND id > :afterId)) " +
            "ORDER BY startedAtUtcMillis ASC, id ASC LIMIT :limit"
    )
    fun syncPage(
        afterStartedAtUtcMillis: Long,
        afterId: String,
        limit: Int
    ): List<SessionEntity>

    @Query(
        "SELECT COUNT(*) FROM session " +
            "WHERE endedAtUtcMillis IS NOT NULL " +
            "AND status != 'FINALIZATION_PENDING' " +
            "AND kind != 'CONTINUOUS' " +
            "AND (startedAtUtcMillis > :afterStartedAtUtcMillis " +
            "OR (startedAtUtcMillis = :afterStartedAtUtcMillis AND id > :afterId))"
    )
    fun syncPendingCount(
        afterStartedAtUtcMillis: Long,
        afterId: String
    ): Long

    @Query("DELETE FROM session WHERE id = :id")
    fun deleteById(id: String): Int

    @Query("DELETE FROM session WHERE id IN (:ids)")
    fun deleteByIds(ids: List<String>): Int

    /**
     * Same G3 hold: a pending session's wall stamps are not yet trustworthy,
     * so battery cycles fold without it until the sweep promotes it.
     */
    @Query(
        "SELECT * FROM session " +
            "WHERE startedAtUtcMillis >= :fromUtcMillis AND endedAtUtcMillis IS NOT NULL " +
            "AND timeState != 'pending' " +
            "ORDER BY startedAtUtcMillis ASC"
    )
    fun closedFrom(fromUtcMillis: Long): List<SessionEntity>

    /** Same G3 hold as [closedFrom]. */
    @Query(
        "SELECT * FROM session " +
            "WHERE startedAtUtcMillis >= :fromUtcMillis AND endedAtUtcMillis IS NOT NULL " +
            "AND timeState != 'pending' " +
            "ORDER BY startedAtUtcMillis ASC"
    )
    fun closedFromAll(fromUtcMillis: Long): List<SessionEntity>

    @Query(
        "SELECT * FROM session " +
            "WHERE endedAtUtcMillis IS NOT NULL " +
            "AND status != 'FINALIZATION_PENDING' " +
            "AND ((kind = 'TRIP' AND rollupTractionWh IS NULL) OR (kind = 'CHARGE' AND rollupDeliveredWh IS NULL)) " +
            "ORDER BY startedAtUtcMillis ASC"
    )
    fun unfinalizedClosed(): List<SessionEntity>

    @Query("SELECT MIN(startedAtUtcMillis) FROM session WHERE kind = :kind")
    fun oldestStartUtcMillis(kind: String): Long?

    @Query("SELECT MIN(startedAtUtcMillis) FROM session")
    fun oldestStartUtcMillisAll(): Long?

    // --- Charge-specific operations ---

    @Query("SELECT * FROM session WHERE kind = 'CHARGE' AND id IN (:ids)")
    fun byIds(ids: List<String>): List<SessionEntity>

    @Query(
        "SELECT * FROM session " +
            "WHERE kind = 'CHARGE' " +
            "AND status != 'FINALIZATION_PENDING' " +
            "AND startedAtUtcMillis >= :startUtcMillis " +
            "ORDER BY startedAtUtcMillis ASC, updatedAtUtcMillis ASC"
    )
    fun since(startUtcMillis: Long): List<SessionEntity>

    @Query(
        "UPDATE session SET " +
            "plugType = :plugType, " +
            "updatedAtUtcMillis = :updatedAtUtcMillis " +
            "WHERE id = :id"
    )
    fun updatePlugType(id: String, plugType: Int, updatedAtUtcMillis: Long): Int

    // --- Parked-specific operations ---

    /**
     * Time authority T6: a PENDING session's wall stamps are not yet
     * trustworthy — a wrong end stamp can make a young session look ancient
     * (false delete) or sort it out of every window (false keep). Age
     * retention therefore never touches a pending session; the sweep
     * resolves it and the next run ages it normally.
     */
    @Query(
        "DELETE FROM session " +
            "WHERE kind = 'PARKED' " +
            "AND COALESCE(endedAtUtcMillis, updatedAtUtcMillis) < :cutoffUtcMillis " +
            "AND endedAtUtcMillis IS NOT NULL " +
            "AND dirty = 0 " +
            "AND timeState != 'pending'"
    )
    fun deleteOlderThan(cutoffUtcMillis: Long): Int

    /**
     * The same purge, held back by what the companion devices confirmed.
     *
     * The sync pages sessions by `(startedAtUtcMillis, id)`, so a device that
     * confirmed one session has confirmed every session that sorts before it.
     * `floorStartedAtUtcMillis` is the least advanced device's position: a row
     * at or before it is on every phone that is syncing, and age alone may
     * retire it. A row after it is on no phone yet, and age must not.
     */
    @Query(
        "DELETE FROM session " +
            "WHERE kind = 'PARKED' " +
            "AND COALESCE(endedAtUtcMillis, updatedAtUtcMillis) < :cutoffUtcMillis " +
            "AND endedAtUtcMillis IS NOT NULL " +
            "AND dirty = 0 " +
            "AND startedAtUtcMillis <= :floorStartedAtUtcMillis " +
            "AND timeState != 'pending'"
    )
    fun deleteOlderThanConfirmed(cutoffUtcMillis: Long, floorStartedAtUtcMillis: Long): Int

    // --- Continuous-specific operations ---

    /**
     * The same purge as [deleteOlderThan], for `CONTINUOUS` rather than
     * `PARKED`. A `CONTINUOUS` session is disposable the same way: retention
     * removes the whole row by age, never a partial one.
     *
     * Finding 5: a session whose child intervals are still dirty survives,
     * even when the session itself is clean. The uploader writes sessions
     * before intervals, so a clean session with dirty children means the
     * children have not reached the cloud yet; deleting the parent would
     * orphan them into `deleteOrphans`, which is ungated GC.
     * ponytail: guard covers interval children only; extend with
     * `NOT IN` on track/trip_segment if dirty-child stranding surfaces there.
     */
    @Query(
        "DELETE FROM session " +
            "WHERE kind = 'CONTINUOUS' " +
            "AND COALESCE(endedAtUtcMillis, updatedAtUtcMillis) < :cutoffUtcMillis " +
            "AND endedAtUtcMillis IS NOT NULL " +
            "AND dirty = 0 " +
            "AND id NOT IN (SELECT sessionId FROM interval WHERE dirty = 1) " +
            "AND timeState != 'pending'"
    )
    fun deleteContinuousOlderThan(cutoffUtcMillis: Long): Int

    /**
     * Finding 1 backstop: the same age purge with no `dirty = 0` gate and
     * no dirty-children guard. Used only when cloud upload can never clear
     * the marks (disabled/unconfigured) or the table exceeds 2x the
     * retention window; without it an unpaired vehicle grows without bound.
     */
    @Query(
        "DELETE FROM session " +
            "WHERE kind = 'CONTINUOUS' " +
            "AND COALESCE(endedAtUtcMillis, updatedAtUtcMillis) < :cutoffUtcMillis " +
            "AND endedAtUtcMillis IS NOT NULL " +
            "AND timeState != 'pending'"
    )
    fun deleteContinuousOlderThanIgnoringDirty(cutoffUtcMillis: Long): Int

    @Query(
        "DELETE FROM session " +
            "WHERE kind = 'CONTINUOUS' " +
            "AND COALESCE(endedAtUtcMillis, updatedAtUtcMillis) < :cutoffUtcMillis " +
            "AND endedAtUtcMillis IS NOT NULL " +
            "AND dirty = 0 " +
            "AND startedAtUtcMillis <= :floorStartedAtUtcMillis " +
            "AND timeState != 'pending'"
    )
    fun deleteContinuousOlderThanConfirmed(cutoffUtcMillis: Long, floorStartedAtUtcMillis: Long): Int

    @Query(
        "UPDATE session SET " +
            "noLongerReducible = 1, " +
            "updatedAtUtcMillis = :updatedAtUtcMillis " +
            "WHERE id = :id"
    )
    fun markNoLongerReducible(id: String, updatedAtUtcMillis: Long = System.currentTimeMillis()): Int

    @Query(
        "SELECT id FROM session " +
            "WHERE (status = 'ENDED' OR status = 'DISCONNECTED' OR endedAtUtcMillis IS NOT NULL) " +
            "AND noLongerReducible = 0 " +
            "AND (climbM IS NOT NULL OR fixCount = 0)"
    )
    fun sessionsEligibleForNoLongerReducible(): List<String>

    /**
     * Time authority T6: the uploader's row source. A PENDING session's
     * stamps will still be corrected, so uploading them now would push a
     * wrong key the backfill must later delete (plan section 5.2); the rows
     * wait with `dirty = 1` and surface here once the close resolves them.
     * Only `pending` is held: `unknown` is the pre-authority legacy state
     * and `uncorrectable` uploads with its marker (plan section 4) — holding
     * either would strand rows no sweep will ever revisit.
     */
    @Query("SELECT * FROM session WHERE dirty = 1 AND timeState != 'pending' LIMIT :limit")
    fun dirtySessions(limit: Int): List<SessionEntity>

    @Query("SELECT COUNT(*) FROM session WHERE dirty = 1 AND timeState != 'pending'")
    fun dirtySessionCount(): Long

    @Query("SELECT COUNT(*) FROM session WHERE dirty = 1 AND timeState = 'pending'")
    fun pendingSessionCount(): Long

    @Query("UPDATE session SET dirty = 0 WHERE id IN (:ids)")
    fun clearDirty(ids: List<String>): Int

    @Query("UPDATE session SET dirty = 1")
    fun markAllDirty(): Int

    @Query("UPDATE session SET timeState = 'uncorrectable' WHERE timeState = 'pending' AND status = 'ENDED'")
    fun promoteEndedPendingToUncorrectable(): Int

    @Query("SELECT DISTINCT vehicleId FROM session WHERE vehicleId IS NOT NULL AND vehicleId != '' AND vehicleId != 'unassigned'")
    fun distinctVehicleIds(): List<String>

    /**
     * Re-marks every session recorded under a retired vehicle id, so the next
     * upload pass rewrites it under the canonical id.
     *
     * Owned by the alias table's write path: it runs once, when an alias is
     * created or re-pointed, never on a schedule — the rows keep their own
     * `vehicle_id`, so a repeated sweep would re-upload them forever.
     */
    @Query("UPDATE session SET dirty = 1 WHERE vehicleId IN (SELECT aliasId FROM vehicle_id_aliases)")
    fun markAliasedSessionsDirty(): Int
}
