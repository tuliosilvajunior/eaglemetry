package com.timhss.capyenergy.telemetry.db

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Time authority T1: the interval minute gains its monotonic pair and a time
 * state on the car and in the cloud.
 *
 * The head unit boots without knowing the time, and 158 of the captain's
 * 15,078 interval rows carry stamps outside the real session window. The
 * monotonic clock does not lie, so once a trusted wall instant arrives for
 * a boot every earlier minute resolves by exact arithmetic — but only when
 * the minute carries its monotonic reading. `SessionEntity` already pairs
 * every stamp with `*ElapsedNanos` and `*BootCount`; the interval had
 * neither, which is why its bad rows are unrecoverable today.
 *
 * Reads the entity, the Room migration, the cloud migration and
 * `schema_full.sql` from files rather than copies, so drift in any of the
 * four fails here. The suites build from `schema_full.sql` and never parse
 * migration files; this test parses both.
 */
class IntervalTimeAuthoritySchemaTest {

    @Test
    fun `IntervalEntity carries the monotonic pair and time state`() {
        val text = entityFile("IntervalEntity.kt").readText()
        assertTrue(
            "IntervalEntity must carry startElapsedNanos",
            text.contains("val startElapsedNanos: Long?")
        )
        assertTrue(
            "IntervalEntity must carry startBootCount",
            text.contains("val startBootCount: Int?")
        )
        assertTrue(
            "IntervalEntity must carry timeState defaulting to unknown",
            text.contains("val timeState: String = \"unknown\"")
        )
        assertTrue(
            "the export row must carry the pair to the cloud",
            text.contains("\"startElapsedNanos\" to startElapsedNanos") &&
                text.contains("\"startBootCount\" to startBootCount") &&
                text.contains("\"timeState\" to timeState")
        )
    }

    @Test
    fun `Room migration 44 to 45 adds the three columns`() {
        val text = entityFile("TelemetryDatabase.kt").readText()
        assertTrue(
            "MIGRATION_44_45 must exist",
            text.contains("MIGRATION_44_45")
        )
        assertTrue(
            "the pair must land nullable with no backfill",
            text.contains("ADD COLUMN `startElapsedNanos` INTEGER DEFAULT NULL") &&
                text.contains("ADD COLUMN `startBootCount` INTEGER DEFAULT NULL")
        )
        assertTrue(
            "timeState must land NOT NULL DEFAULT 'unknown'",
            text.contains("ADD COLUMN `timeState` TEXT NOT NULL DEFAULT 'unknown'")
        )
        assertTrue(
            "the migration must be registered",
            text.contains("MIGRATION_44_45") && text.contains("SCHEMA_VERSION = 48")
        )
    }

    @Test
    fun `cloud migration adds the pair state and corrected-from marker`() {
        val text = migrationFile().readText()
        assertTrue(
            "the cloud pair must stay nullable",
            text.contains(Regex("""start_elapsed_nanos\s+bigint""", RegexOption.IGNORE_CASE)) &&
                text.contains(Regex("""start_boot_count\s+bigint""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "time_state must default to unknown",
            text.contains(Regex("""time_state\s+text\s+not null default 'unknown'""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "the corrected-from marker must exist for the later cloud task",
            text.contains(Regex("""corrected_from_utc_millis\s+bigint""", RegexOption.IGNORE_CASE))
        )
    }

    @Test
    fun `schema_full interval matches the migration`() {
        val schema = supabaseSchemaFile().readText()
        val body = tableBody(schema, "interval")
        assertTrue("schema_full.sql must declare the interval table", body != null)
        val migration = migrationFile().readText()
        for (column in listOf("start_elapsed_nanos", "start_boot_count", "time_state", "corrected_from_utc_millis")) {
            assertTrue(
                "schema_full.sql interval must declare $column",
                body!!.contains(column)
            )
            assertTrue(
                "the migration must declare $column",
                migration.contains(column)
            )
        }
    }

    // --- helpers -------------------------------------------------------------

    private fun entityFile(name: String): File {
        var dir = File("").absoluteFile
        while (dir.parentFile != null) {
            val candidate = File(dir, "android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/db/$name")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Could not find $name from ${File("").absolutePath}")
    }

    private fun supabaseSchemaFile(): File {
        var dir = File("").absoluteFile
        while (dir.parentFile != null) {
            val candidate = File(dir, "supabase/schema_full.sql")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Could not find supabase/schema_full.sql from ${File("").absolutePath}")
    }

    private fun migrationFile(): File {
        var dir = File("").absoluteFile
        while (dir.parentFile != null) {
            val candidate = File(dir, "supabase/migrations/20260911233000_interval_time_authority_columns.sql")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Could not find interval time authority migration from ${File("").absolutePath}")
    }

    private fun tableBody(schema: String, table: String): String? {
        return Regex(
            """create table (?:if not exists )?(?:public\.)"?""" + Regex.escape(table) + """"? \((.+?)^\)""",
            setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.MULTILINE, RegexOption.IGNORE_CASE)
        ).find(schema)?.groupValues?.get(1)
    }
}
