package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface SessionCostDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(cost: SessionCostEntity)

    @Query("SELECT * FROM session_costs WHERE sessionId = :sessionId LIMIT 1")
    fun findById(sessionId: String): SessionCostEntity?

    @Query("SELECT * FROM session_costs WHERE sessionId IN (:sessionIds)")
    fun forSessions(sessionIds: List<String>): List<SessionCostEntity>

    @Query("SELECT * FROM session_costs ORDER BY updatedAtUtcMillis ASC, sessionId ASC")
    fun all(): List<SessionCostEntity>

    @Query(
        "SELECT * FROM session_costs " +
            "WHERE updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND sessionId > :afterSessionId) " +
            "ORDER BY updatedAtUtcMillis ASC, sessionId ASC LIMIT :limit"
    )
    fun syncPage(afterUpdatedAtUtcMillis: Long, afterSessionId: String, limit: Int): List<SessionCostEntity>

    @Query(
        "SELECT COUNT(*) FROM session_costs " +
            "WHERE updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND sessionId > :afterSessionId)"
    )
    fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterSessionId: String): Long

    @Query(
        "SELECT s.id FROM session s " +
            "WHERE s.kind = 'CHARGE' " +
            "AND s.endedAtUtcMillis IS NOT NULL " +
            "AND s.status != 'FINALIZATION_PENDING' " +
            "AND s.id NOT IN (SELECT sessionId FROM session_costs WHERE costPerKwh IS NOT NULL OR paidAmount IS NOT NULL) " +
            "ORDER BY s.startedAtUtcMillis ASC, s.id ASC"
    )
    fun unpricedClosedChargeSessionIds(): List<String>

    @Query(
        "SELECT MIN(s.startedAtUtcMillis) FROM session s " +
            "WHERE s.kind = 'CHARGE' " +
            "AND s.endedAtUtcMillis IS NOT NULL " +
            "AND s.status != 'FINALIZATION_PENDING' " +
            "AND s.id NOT IN (SELECT sessionId FROM session_costs WHERE costPerKwh IS NOT NULL OR paidAmount IS NOT NULL)"
    )
    fun oldestUnpricedClosedStart(): Long?

    /**
     * The cost of the newest closed charge that ended before [beforeUtcMillis]
     * and carries a rate. This is what a drive is scored at: the rate of the
     * charge that filled it, which is an earlier session.
     */
    @Query(
        "SELECT c.* FROM session_costs c " +
            "INNER JOIN session s ON s.id = c.sessionId " +
            "WHERE s.kind = 'CHARGE' " +
            "AND s.status != 'FINALIZATION_PENDING' " +
            "AND s.chargeStartedAtUtcMillis IS NOT NULL " +
            "AND c.costPerKwh IS NOT NULL AND c.costPerKwh >= 0.0 " +
            "AND s.endedAtUtcMillis IS NOT NULL " +
            "AND s.endedAtUtcMillis <= :beforeUtcMillis " +
            "ORDER BY s.endedAtUtcMillis DESC, s.startedAtUtcMillis DESC LIMIT 1"
    )
    fun latestPricedBefore(beforeUtcMillis: Long): SessionCostEntity?
}
