package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.db.BatteryCycleDao
import com.timhss.capyenergy.telemetry.db.InsightPlaceDao
import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.JourneyDao
import com.timhss.capyenergy.telemetry.db.PreferenceDao
import com.timhss.capyenergy.telemetry.db.PreferenceProposalDao
import com.timhss.capyenergy.telemetry.db.SessionCostDao
import com.timhss.capyenergy.telemetry.db.SessionDao
import com.timhss.capyenergy.telemetry.db.SyncCursorDao
import com.timhss.capyenergy.telemetry.db.SyncCursorEntity
import com.timhss.capyenergy.telemetry.db.TelemetryEventDao
import com.timhss.capyenergy.telemetry.db.TrackDao

/**
 * Result of processing a [SyncAckRequest].
 */
sealed class SyncAckResult {
    data class Applied(val cursor: SyncCursorEntity) : SyncAckResult()
    data class Failed(val reason: String) : SyncAckResult()
    data class StaleOrIgnored(val reason: String) : SyncAckResult()
    data class Rejected(val reason: String) : SyncAckResult()
}

/**
 * Incoming synchronization acknowledgement payload.
 */
data class SyncAckRequest(
    val deviceId: String,
    val streamType: String,
    val recordId: String,
    val syncedAtHlcMillis: Long,
    val syncedAtHlcCounter: Int,
    val syncedAtHlcDeviceId: String,
    val success: Boolean,
    val error: String? = null,
    val recordIds: List<String> = emptyList()
) {
    val confirmedRecordIds: List<String>
        get() = if (recordIds.isEmpty()) listOf(recordId) else recordIds
}

class SyncCursorRepository(
    private val syncCursorDao: SyncCursorDao,
    private val isDevicePaired: (String) -> Boolean,
    private val sessionDao: SessionDao? = null,
    private val intervalDao: IntervalDao? = null,
    private val batteryCycleDao: BatteryCycleDao? = null,
    private val telemetryEventDao: TelemetryEventDao? = null,
    private val insightPlaceDao: InsightPlaceDao? = null,
    private val sessionCostDao: SessionCostDao? = null,
    private val preferenceDao: PreferenceDao? = null,
    private val preferenceProposalDao: PreferenceProposalDao? = null,
    private val journeyDao: JourneyDao? = null,
    private val trackDao: TrackDao? = null
) {
    fun getCursor(deviceId: String, streamType: String): SyncCursorEntity? {
        if (deviceId.isBlank() || streamType.isBlank()) return null
        return syncCursorDao.getCursor(deviceId.trim(), streamType.trim())
    }

    fun getCursorsForDevice(deviceId: String): List<SyncCursorEntity> {
        if (deviceId.isBlank()) return emptyList()
        return syncCursorDao.getCursorsForDevice(deviceId.trim())
    }

    @Synchronized
    fun acknowledge(
        ack: SyncAckRequest,
        nowUtcMillis: Long = System.currentTimeMillis()
    ): SyncAckResult {
        val deviceId = ack.deviceId.trim()
        val streamName = ack.streamType.trim()
        val recordIds = ack.confirmedRecordIds.map { it.trim() }.filter { it.isNotBlank() }
        val recordId = recordIds.lastOrNull().orEmpty()

        if (deviceId.isBlank() || streamName.isBlank() || recordId.isBlank()) {
            return SyncAckResult.Rejected("Missing deviceId, streamType or recordId")
        }

        // Invariant 1: Device must be paired
        if (!isDevicePaired(deviceId)) {
            return SyncAckResult.Rejected("Device $deviceId is not paired or has been revoked")
        }

        // Invariant 2: Stream type must be valid
        val streamType = SyncStreamType.fromWireName(streamName)
            ?: return SyncAckResult.Rejected("Unknown streamType: $streamName")

        // Invariant 6: Distinguish explicit failures from stale replays
        if (!ack.success) {
            return SyncAckResult.Failed(ack.error ?: "unspecified delivery failure")
        }

        // Invariant 3: Every record must exist locally
        for (id in recordIds) {
            if (!verifyRecordExists(streamType, id)) {
                return SyncAckResult.Rejected("Record $id does not exist in $streamName")
            }
        }

        // Invariant 4: Clock drift protection
        if (ack.syncedAtHlcMillis > nowUtcMillis + MAX_DRIFT_MILLIS) {
            return SyncAckResult.Rejected(
                "ACK timestamp ${ack.syncedAtHlcMillis} exceeds maximum clock drift (local=$nowUtcMillis, maxDrift=$MAX_DRIFT_MILLIS)"
            )
        }

        val current = syncCursorDao.getCursor(deviceId, streamType.wireName)

        // Invariant 5: Monotonic causal ordering
        if (current != null && current.lastConfirmedHlcMillis != null) {
            val currentMillis = current.lastConfirmedHlcMillis
            val currentCounter = current.lastConfirmedHlcCounter ?: 0
            val currentHlcDev = current.lastConfirmedHlcDeviceId ?: ""

            val comparison = compareHlc(
                ack.syncedAtHlcMillis, ack.syncedAtHlcCounter, ack.syncedAtHlcDeviceId,
                currentMillis, currentCounter, currentHlcDev
            )

            if (comparison <= 0) {
                return SyncAckResult.StaleOrIgnored("ACK is older than or equal to current cursor")
            }
        }

        val newCursor = SyncCursorEntity(
            deviceId = deviceId,
            streamType = streamType.wireName,
            lastConfirmedRecordId = recordId,
            lastConfirmedHlcMillis = ack.syncedAtHlcMillis,
            lastConfirmedHlcCounter = ack.syncedAtHlcCounter,
            lastConfirmedHlcDeviceId = ack.syncedAtHlcDeviceId,
            updatedAtUtcMillis = nowUtcMillis
        )

        syncCursorDao.upsert(newCursor)
        return SyncAckResult.Applied(newCursor)
    }

    @Synchronized
    fun clearForDevice(deviceId: String): Int {
        if (deviceId.isBlank()) return 0
        return syncCursorDao.deleteForDevice(deviceId.trim())
    }

    private fun verifyRecordExists(streamType: SyncStreamType, recordId: String): Boolean {
        return when (streamType) {
            SyncStreamType.SESSIONS -> {
                sessionDao?.findById(recordId) != null
            }
            SyncStreamType.TELEMETRY_FRAMES -> {
                sessionDao?.findById(recordId) != null
            }
            SyncStreamType.BATTERY_CYCLES -> {
                val ordinal = recordId.toLongOrNull() ?: return false
                val maxOrdinal = batteryCycleDao?.maxOrdinal() ?: return false
                ordinal in 1..maxOrdinal
            }
            SyncStreamType.INTERVALS -> {
                val parts = recordId.split(":")
                if (parts.size != 2) return false
                val sessionId = parts[0].trim()
                val startUtcMillis = parts[1].trim().toLongOrNull() ?: return false
                intervalDao?.findById(sessionId, startUtcMillis) != null
            }
            SyncStreamType.EVENTS -> {
                val id = recordId.toLongOrNull() ?: return false
                telemetryEventDao?.findById(id) != null
            }
            SyncStreamType.PLACES -> {
                val id = recordId.split(":").lastOrNull()?.trim().orEmpty()
                insightPlaceDao?.findById(id) != null
            }
            SyncStreamType.SESSION_COSTS -> {
                val sessionId = recordId.split(":").lastOrNull()?.trim().orEmpty()
                sessionCostDao?.findById(sessionId) != null
            }
            SyncStreamType.PREFERENCES -> {
                val parts = recordId.split(":")
                if (parts.size != 3) return false
                val scope = parts[1].trim()
                val key = parts[2].trim()
                preferenceDao?.findById(scope, key) != null
            }
            SyncStreamType.PREFERENCE_PROPOSALS -> {
                val id = recordId.split(":").lastOrNull()?.trim().orEmpty()
                preferenceProposalDao?.findById(id) != null
            }
            SyncStreamType.JOURNEYS -> {
                val id = recordId.split(":").lastOrNull()?.trim().orEmpty()
                journeyDao?.findById(id) != null
            }
            SyncStreamType.TRACKS -> {
                val sessionId = recordId.split(":").lastOrNull()?.trim().orEmpty()
                (trackDao?.countForSession(sessionId) ?: 0L) > 0L
            }
        }
    }

    companion object {
        const val MAX_DRIFT_MILLIS = 30 * 60 * 1000L

        fun compareHlc(
            m1: Long, c1: Int, d1: String,
            m2: Long, c2: Int, d2: String
        ): Int {
            if (m1 != m2) return m1.compareTo(m2)
            if (c1 != c2) return c1.compareTo(c2)
            return d1.compareTo(d2)
        }
    }
}
