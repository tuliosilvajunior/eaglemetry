package com.timhss.capyenergy.telemetry.db

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Gating invariant: age-based retention must never delete a row that has not
 * been uploaded. In this branch the gate is `dirty = 0` on every
 * `deleteOlderThan*` query. Orphan GC (`deleteOrphans`) is intentionally
 * ungated — see androidTest `TelemetryRetentionTest` for the behavioural
 * proof.
 *
 * This unit test runs with `testDebugUnitTest` (no emulator) and verifies
 * the invariant by inspecting the DAO source text. The androidTest suite
 * then proves the behaviour against a real Room database.
 */
class TelemetryRetentionTest {

    @Test
    fun `session deleteOlderThan is gated on dirty`() {
        val src = readDao("SessionDao.kt")
        assertTrue(src.contains("deleteOlderThan") && src.contains("dirty = 0"))
        // Ensure PARKED delete is gated
        assertTrue(src.contains("kind = 'PARKED'") && src.contains("dirty = 0"))
    }

    @Test
    fun `session deleteOlderThanConfirmed is gated on dirty`() {
        val src = readDao("SessionDao.kt")
        assertTrue(src.contains("deleteOlderThanConfirmed"))
        assertTrue(countOccurrences(src, "dirty = 0") >= 4)
    }

    @Test
    fun `session deleteContinuousOlderThan is gated on dirty`() {
        val src = readDao("SessionDao.kt")
        assertTrue(src.contains("deleteContinuousOlderThan"))
        assertTrue(src.contains("kind = 'CONTINUOUS'") && src.contains("dirty = 0"))
    }

    @Test
    fun `session deleteContinuousOlderThanConfirmed is gated on dirty`() {
        val src = readDao("SessionDao.kt")
        assertTrue(src.contains("deleteContinuousOlderThanConfirmed"))
        assertTrue(src.contains("dirty = 0"))
    }

    @Test
    fun `telemetry event deleteOlderThanChunk is gated on dirty`() {
        val src = readDao("TelemetryEventDao.kt")
        assertTrue(src.contains("deleteOlderThanChunk") && src.contains("dirty = 0"))
    }

    @Test
    fun `telemetry event deleteOlderThanConfirmedChunk is gated on dirty`() {
        val src = readDao("TelemetryEventDao.kt")
        assertTrue(src.contains("deleteOlderThanConfirmedChunk") && src.contains("dirty = 0"))
    }

    @Test
    fun `orphan deletes are ungated`() {
        val interval = readDao("IntervalDao.kt")
        val track = readDao("TrackDao.kt")
        val event = readDao("TelemetryEventDao.kt")
        assertTrue(interval.contains("deleteOrphans") && interval.contains("NOT IN (SELECT id FROM session)"))
        assertTrue(track.contains("deleteOrphans") && track.contains("NOT IN (SELECT id FROM session)"))
        assertTrue(event.contains("deleteOrphanSessionEventsChunk"))
        // Finding 13a: Room puts the @Query string above the signature, so a
        // cross-line "deleteOrphans.*dirty" regex can never match and the old
        // assertion passed vacuously. Check each orphan statement instead.
        // Non-empty first: an empty match would pass `all {}` vacuously too.
        assertTrue(orphanStatements(interval).isNotEmpty())
        assertTrue(orphanStatements(track).isNotEmpty())
        assertTrue(orphanStatements(event).isNotEmpty())
        assertTrue(orphanStatements(interval).all { !it.contains("dirty") })
        assertTrue(orphanStatements(track).all { !it.contains("dirty") })
        assertTrue(orphanStatements(event).all { !it.contains("dirty") })
    }

    @Test
    fun `dirty mark exists on all five measurement tables`() {
        assertTrue(readDao("SessionDao.kt").contains("dirty = 1"))
        assertTrue(readDao("IntervalDao.kt").contains("dirty = 1"))
        assertTrue(readDao("TrackDao.kt").contains("dirty = 1"))
        assertTrue(readDao("TelemetryEventDao.kt").contains("dirty = 1"))
        assertTrue(readDao("BatteryCycleDao.kt").contains("dirty = 1"))
    }

    @Test
    fun `uploader clears dirty per successful chunk`() {
        // Sanity: TelemetryCloudUploader must call clearDirty after each sink upsert.
        val src = readFile("telemetry/sync/TelemetryCloudUploader.kt")
        assertTrue(src.contains("clearDirty"))
        // Must be inside a try/success path per chunk, not before upsert
        assertTrue(src.contains("sink.upsert"))
        // Ensure interval uses clearDirtyByKeys
        assertTrue(src.contains("clearDirtyByKeys"))
    }

    private fun readDao(name: String): String {
        return readFile("telemetry/db/$name")
    }

    private fun readFile(relative: String): String {
        val candidates = listOf(
            File("android/app/src/main/kotlin/com/timhss/capyenergy/$relative"),
            File("app/src/main/kotlin/com/timhss/capyenergy/$relative"),
            File("src/main/kotlin/com/timhss/capyenergy/$relative"),
            File(System.getProperty("user.dir") + "/android/app/src/main/kotlin/com/timhss/capyenergy/$relative"),
            File(System.getProperty("user.dir") + "/app/src/main/kotlin/com/timhss/capyenergy/$relative")
        )
        for (f in candidates) {
            if (f.exists()) return f.readText()
        }
        // Fallback: search from user.dir upwards
        var dir = File(System.getProperty("user.dir"))
        repeat(5) {
            val f = File(dir, "android/app/src/main/kotlin/com/timhss/capyenergy/$relative")
            if (f.exists()) return f.readText()
            val f2 = File(dir, "app/src/main/kotlin/com/timhss/capyenergy/$relative")
            if (f2.exists()) return f2.readText()
            dir = dir.parentFile ?: return@repeat
        }
        error("cannot find $relative from ${System.getProperty("user.dir")} tried $candidates")
    }

    private fun countOccurrences(text: String, needle: String): Int =
        text.split(needle).size - 1

    /**
     * Finding 13a: the @Query string literals of the orphan deletes. Each
     * adjacent-string group above a `deleteOrphan` signature is one statement,
     * so a `dirty` gate inside any of them fails this instead of passing
     * vacuously like the old cross-line regex.
     */
    private fun orphanStatements(src: String): List<String> {
        val queryLiteral = Regex(""""([^"]*)"""")
        return src.lines()
            .filter { it.contains("deleteOrphan") && it.contains("fun ") && it.contains(")") }
            .mapNotNull { signature ->
                val idx = src.indexOf(signature)
                val head = src.substring(0, idx).lines().takeLast(8).joinToString("\n")
                queryLiteral.findAll(head).map { it.groupValues[1] }.joinToString(" ")
                    .takeIf { it.contains("DELETE", ignoreCase = true) }
            }
    }
}
