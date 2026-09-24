package com.timhss.capyenergy.telemetry

import android.content.Context
import android.provider.Settings
import android.util.Log
import com.timhss.capyenergy.telemetry.db.SessionEntity

/**
 * Decides whether a session's frames share one `elapsedRealtimeNanos` axis.
 */
internal object SessionTimeline {
    fun spansReboot(session: SessionEntity, currentBootCount: Int? = null): Boolean = spansReboot(
        recorded = listOf(
            session.startedAtBootCount,
            session.movementStartedAtBootCount,
            session.chargeStartedAtBootCount,
            session.chargeEndedAtBootCount,
            session.plugDisconnectedAtBootCount,
            session.endedAtBootCount
        ),
        closed = session.endedAtBootCount != null || session.plugDisconnectedAtBootCount != null,
        currentBootCount = currentBootCount
    )

    private fun spansReboot(
        recorded: List<Int?>,
        closed: Boolean,
        currentBootCount: Int?
    ): Boolean {
        val counters = recorded.filterNotNull().toMutableList()
        if (counters.isEmpty()) return false
        if (!closed) currentBootCount?.let(counters::add)
        return counters.distinct().size > 1
    }

    fun rebasedElapsedNanos(wallTimeUtcMillis: Long, baseWallUtcMillis: Long): Long =
        (wallTimeUtcMillis - baseWallUtcMillis).coerceAtLeast(0L) * 1_000_000L + 1L

    fun currentBootCount(context: Context): Int? = try {
        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT)
            .takeIf { it >= 0 }
    } catch (e: Exception) {
        Log.w(TAG, "Unable to read Android boot count", e)
        null
    }

    private const val TAG = "SessionTimeline"
}
