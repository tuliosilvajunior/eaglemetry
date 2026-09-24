package com.timhss.capyenergy.telemetry

import android.content.Context
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import java.io.File

class DatabaseHealthReporter(
    context: Context,
    private val database: TelemetryDatabase
) {
    private val databaseFile = context.applicationContext.getDatabasePath(DATABASE_NAME)

    @Volatile
    private var lastRefreshElapsedNanos = 0L

    @Volatile
    private var snapshot: Map<String, Any?> = mapOf("available" to false)

    fun refreshIfStale() {
        val now = System.nanoTime()
        if (lastRefreshElapsedNanos != 0L &&
            now - lastRefreshElapsedNanos < REFRESH_INTERVAL_NANOS
        ) return
        synchronized(this) {
            if (lastRefreshElapsedNanos != 0L &&
                now - lastRefreshElapsedNanos < REFRESH_INTERVAL_NANOS
            ) return
            snapshot = buildSnapshot()
            lastRefreshElapsedNanos = now
        }
    }

    fun statusMap(): Map<String, Any?> = snapshot

    /**
     * How much disk the app's stored history occupies, without scanning any row.
     *
     * Read from `PRAGMA page_count` / `freelist_count` / `page_size` — O(1)
     * header reads — plus `File.length` for the WAL/SHM sidecars. With
     * `auto_vacuum = FULL` (the setting on all four car snapshots) the file
     * truncates on every commit, so logical size (`used pages * page size`)
     * and `File.length` are the same after a wipe (15_102 pages / 47 MB
     * before a DELETE, 618 pages / 2.5 MB after, freelist always 0). The
     * pragma form is kept because it makes the intent explicit.
     *
     * A total failure returns `bytes = -1` so the UI can show `--` instead of
     * `0 B`.
     */
    fun storageUsage(): Map<String, Any?> = try {
        val sqlite = database.openHelper.writableDatabase
        val pageCount = sqlite.longPragma("page_count")
        val freelistCount = sqlite.longPragma("freelist_count")
        val pageSize = sqlite.longPragma("page_size")
        val usedBytes = (pageCount - freelistCount).coerceAtLeast(0L) * pageSize
        val walBytes = File(databaseFile.path + "-wal").safeLength()
        val shmBytes = File(databaseFile.path + "-shm").safeLength()
        val total = usedBytes + walBytes + shmBytes
        mapOf(
            "bytes" to total,
            "databaseBytes" to usedBytes,
            "walBytes" to walBytes,
            "shmBytes" to shmBytes,
            "pageCount" to pageCount,
            "freelistCount" to freelistCount,
            "pageSizeBytes" to pageSize,
        )
    } catch (e: Exception) {
        mapOf(
            "bytes" to -1,
            "databaseBytes" to -1,
            "walBytes" to 0,
            "shmBytes" to 0,
            "error" to "${e.javaClass.simpleName}: ${e.message}".take(500),
        )
    }

    private fun buildSnapshot(): Map<String, Any?> = try {
        val sqlite = database.openHelper.writableDatabase
        val pageCount = sqlite.longPragma("page_count")
        val freelistCount = sqlite.longPragma("freelist_count")
        val pageSize = sqlite.longPragma("page_size")
        mapOf(
            "available" to true,
            "journalMode" to sqlite.stringPragma("journal_mode"),
            "databaseBytes" to databaseFile.safeLength(),
            "walBytes" to File(databaseFile.path + "-wal").safeLength(),
            "shmBytes" to File(databaseFile.path + "-shm").safeLength(),
            "pageCount" to pageCount,
            "freelistCount" to freelistCount,
            "usedPageCount" to (pageCount - freelistCount).coerceAtLeast(0L),
            "pageSizeBytes" to pageSize,
            "inTransaction" to sqlite.inTransaction(),
            // Observability must not mutate checkpoint state.
            "checkpointInvoked" to false,
            "observedAtUtcMillis" to System.currentTimeMillis(),
            "error" to null
        )
    } catch (error: Exception) {
        mapOf(
            "available" to false,
            "observedAtUtcMillis" to System.currentTimeMillis(),
            "error" to "${error.javaClass.simpleName}: ${error.message}".take(500)
        )
    }

    private fun androidx.sqlite.db.SupportSQLiteDatabase.longPragma(name: String): Long {
        query("PRAGMA $name").use { cursor ->
            return if (cursor.moveToFirst()) cursor.getLong(0) else 0L
        }
    }

    private fun androidx.sqlite.db.SupportSQLiteDatabase.stringPragma(name: String): String? {
        query("PRAGMA $name").use { cursor ->
            return if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }

    private fun File.safeLength(): Long = if (exists()) length() else 0L

    private companion object {
        const val DATABASE_NAME = "geely_telemetry.db"
        const val REFRESH_INTERVAL_NANOS = 30_000_000_000L
    }
}
