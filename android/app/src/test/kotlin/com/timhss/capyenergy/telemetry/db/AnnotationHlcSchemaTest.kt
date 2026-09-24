package com.timhss.capyenergy.telemetry.db

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 2 Lane B Step 1: cloud annotation tables gain hybrid logical clock stamps.
 *
 * Verifies `supabase/schema_full.sql` and the migration
 * `20260902120000_annotation_hlc_stamps.sql` declare per-field-group HLC triples
 * for insight_places, session_costs, journeys and a row-level triple for preferences.
 *
 * Each triple mirrors `HlcTimestamp` in `packages/telemetry_core/lib/dto/sync_models.dart`:
 *   <group>_hlc_millis  bigint   NOT NULL DEFAULT 0
 *   <group>_hlc_counter integer  NOT NULL DEFAULT 0
 *   <group>_hlc_device_id text   NOT NULL DEFAULT ''
 *
 * Reads SQL from files rather than a copy, so a later migration drift fails.
 */
class AnnotationHlcSchemaTest {

    // -- insight_places: 3 groups (name, geofence, auto_name) -----------------------------

    @Test
    fun `insight_places has name and geofence HLC triples`() {
        val schema = supabaseSchemaText()
        val body = tableBody(schema, "insight_places")
            ?: error("insight_places not found in schema_full.sql")
        // name group
        assertTrue(
            "insight_places must have name_hlc_millis bigint not null default 0",
            body.contains(Regex("""name_hlc_millis\s+bigint\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "insight_places must have name_hlc_counter integer not null default 0",
            body.contains(Regex("""name_hlc_counter\s+integer\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "insight_places must have name_hlc_device_id text not null default ''",
            body.contains(Regex("""name_hlc_device_id\s+text\s+not null\s+default\s+''""", RegexOption.IGNORE_CASE))
        )
        // geofence group
        assertTrue(
            "insight_places must have geofence_hlc_millis bigint not null default 0",
            body.contains(Regex("""geofence_hlc_millis\s+bigint\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "insight_places must have geofence_hlc_counter integer not null default 0",
            body.contains(Regex("""geofence_hlc_counter\s+integer\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "insight_places must have geofence_hlc_device_id text not null default ''",
            body.contains(Regex("""geofence_hlc_device_id\s+text\s+not null\s+default\s+''""", RegexOption.IGNORE_CASE))
        )
        // auto_name group (M-3, ADR 0009)
        assertTrue(
            "insight_places must have auto_name_hlc_millis bigint not null default 0",
            body.contains(Regex("""auto_name_hlc_millis\s+bigint\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "insight_places must have auto_name_hlc_counter integer not null default 0",
            body.contains(Regex("""auto_name_hlc_counter\s+integer\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "insight_places must have auto_name_hlc_device_id text not null default ''",
            body.contains(Regex("""auto_name_hlc_device_id\s+text\s+not null\s+default\s+''""", RegexOption.IGNORE_CASE))
        )
        // also in migration
        val migration = migrationText()
        assertTrue("migration must alter insight_places for name_hlc_millis", migration.contains("name_hlc_millis"))
        assertTrue("migration must alter insight_places for geofence_hlc_millis", migration.contains("geofence_hlc_millis"))
    }

    // -- session_costs: 1 group (cost) ---------------------------------------

    @Test
    fun `session_costs has cost HLC triple`() {
        val schema = supabaseSchemaText()
        val body = tableBody(schema, "session_costs")
            ?: error("session_costs not found in schema_full.sql")
        assertTrue(
            "session_costs must have cost_hlc_millis bigint not null default 0",
            body.contains(Regex("""cost_hlc_millis\s+bigint\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "session_costs must have cost_hlc_counter integer not null default 0",
            body.contains(Regex("""cost_hlc_counter\s+integer\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "session_costs must have cost_hlc_device_id text not null default ''",
            body.contains(Regex("""cost_hlc_device_id\s+text\s+not null\s+default\s+''""", RegexOption.IGNORE_CASE))
        )
        val migration = migrationText()
        assertTrue("migration must alter session_costs for cost_hlc_millis", migration.contains("cost_hlc_millis"))
    }

    // -- journeys: 3 groups (name, note, time_range) -------------------------

    @Test
    fun `journeys has name note and time_range HLC triples`() {
        val schema = supabaseSchemaText()
        val body = tableBody(schema, "journeys")
            ?: error("journeys not found in schema_full.sql")
        // name
        assertTrue(
            "journeys must have name_hlc_millis bigint not null default 0",
            body.contains(Regex("""name_hlc_millis\s+bigint\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "journeys must have name_hlc_counter integer not null default 0",
            body.contains(Regex("""name_hlc_counter\s+integer\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "journeys must have name_hlc_device_id text not null default ''",
            body.contains(Regex("""name_hlc_device_id\s+text\s+not null\s+default\s+''""", RegexOption.IGNORE_CASE))
        )
        // note
        assertTrue(
            "journeys must have note_hlc_millis bigint not null default 0",
            body.contains(Regex("""note_hlc_millis\s+bigint\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "journeys must have note_hlc_counter integer not null default 0",
            body.contains(Regex("""note_hlc_counter\s+integer\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "journeys must have note_hlc_device_id text not null default ''",
            body.contains(Regex("""note_hlc_device_id\s+text\s+not null\s+default\s+''""", RegexOption.IGNORE_CASE))
        )
        // time_range
        assertTrue(
            "journeys must have time_range_hlc_millis bigint not null default 0",
            body.contains(Regex("""time_range_hlc_millis\s+bigint\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "journeys must have time_range_hlc_counter integer not null default 0",
            body.contains(Regex("""time_range_hlc_counter\s+integer\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "journeys must have time_range_hlc_device_id text not null default ''",
            body.contains(Regex("""time_range_hlc_device_id\s+text\s+not null\s+default\s+''""", RegexOption.IGNORE_CASE))
        )
        val migration = migrationText()
        assertTrue("migration must alter journeys for name_hlc_millis", migration.contains("name_hlc_millis"))
        assertTrue("migration must alter journeys for note_hlc_millis", migration.contains("note_hlc_millis"))
        assertTrue("migration must alter journeys for time_range_hlc_millis", migration.contains("time_range_hlc_millis"))
    }

    // -- preferences: row-level HLC ------------------------------------------

    @Test
    fun `preferences has row-level HLC triple`() {
        val schema = supabaseSchemaText()
        val body = tableBody(schema, "preferences")
            ?: error("preferences not found in schema_full.sql")
        // Row-level columns are bare hlc_* (not prefixed), because row == field
        // for a key/value table.
        assertTrue(
            "preferences must have hlc_millis bigint not null default 0",
            body.contains(Regex("""\bhlc_millis\s+bigint\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "preferences must have hlc_counter integer not null default 0",
            body.contains(Regex("""\bhlc_counter\s+integer\s+not null\s+default\s+0""", RegexOption.IGNORE_CASE))
        )
        assertTrue(
            "preferences must have hlc_device_id text not null default ''",
            body.contains(Regex("""\bhlc_device_id\s+text\s+not null\s+default\s+''""", RegexOption.IGNORE_CASE))
        )
        val migration = migrationText()
        assertTrue("migration must alter preferences for hlc_millis", migration.contains("hlc_millis") && migration.contains("public.preferences"))
    }

    // -- existing columns unchanged ------------------------------------------

    @Test
    fun `existing annotation columns are untouched`() {
        val schema = supabaseSchemaText()
        // insight_places still has original columns
        val ipBody = tableBody(schema, "insight_places") ?: error("insight_places missing")
        assertTrue("insight_places must still have name text not null", ipBody.contains(Regex("""\bname\s+text\s+not null""", RegexOption.IGNORE_CASE)))
        assertTrue("insight_places must still have latitude", ipBody.contains(Regex("""latitude\s+double precision\s+not null""", RegexOption.IGNORE_CASE)))
        assertTrue("insight_places must still have radius_m", ipBody.contains(Regex("""radius_m\s+double precision\s+not null""", RegexOption.IGNORE_CASE)))
        assertTrue("insight_places must still have updated_at_utc_millis", ipBody.contains(Regex("""updated_at_utc_millis\s+bigint\s+not null""", RegexOption.IGNORE_CASE)))
        // session_costs
        val scBody = tableBody(schema, "session_costs") ?: error("session_costs missing")
        assertTrue("session_costs must still have cost_per_kwh", scBody.contains(Regex("""cost_per_kwh\s+double precision""", RegexOption.IGNORE_CASE)))
        assertTrue("session_costs must still have cost_currency", scBody.contains(Regex("""cost_currency\s+text""", RegexOption.IGNORE_CASE)))
        // journeys
        val jBody = tableBody(schema, "journeys") ?: error("journeys missing")
        assertTrue("journeys must still have note text", jBody.contains(Regex("""note\s+text""", RegexOption.IGNORE_CASE)))
        assertTrue("journeys must still have started_at_utc_millis", jBody.contains(Regex("""started_at_utc_millis\s+bigint\s+not null""", RegexOption.IGNORE_CASE)))
        // preferences
        val prefBody = tableBody(schema, "preferences") ?: error("preferences missing")
        assertTrue("preferences must still have value text", prefBody.contains(Regex("""value\s+text""", RegexOption.IGNORE_CASE)))
    }

    // -- migration file exists ------------------------------------------------

    @Test
    fun `migration file exists with all four tables`() {
        val file = migrationFile()
        assertTrue("Migration file must exist at ${file.path}", file.isFile)
        val text = file.readText()
        assertTrue("Migration must alter insight_places", text.contains(Regex("""alter table.*insight_places""", RegexOption.IGNORE_CASE)))
        assertTrue("Migration must alter session_costs", text.contains(Regex("""alter table.*session_costs""", RegexOption.IGNORE_CASE)))
        assertTrue("Migration must alter journeys", text.contains(Regex("""alter table.*journeys""", RegexOption.IGNORE_CASE)))
        assertTrue("Migration must alter preferences", text.contains(Regex("""alter table.*preferences""", RegexOption.IGNORE_CASE)))
    }

    @Test
    fun `HLC shape mirrors HlcTimestamp (millis bigint, counter integer, deviceId text)`() {
        val combined = supabaseSchemaText() + "\n" + migrationText()
        // Every _hlc_millis must be bigint, every _hlc_counter integer, every _hlc_device_id text
        val millisCols = Regex("""\w+_hlc_millis\s+bigint""", RegexOption.IGNORE_CASE).findAll(combined).count()
        val counterCols = Regex("""\w+_hlc_counter\s+integer""", RegexOption.IGNORE_CASE).findAll(combined).count()
        val deviceCols = Regex("""\w+_hlc_device_id\s+text""", RegexOption.IGNORE_CASE).findAll(combined).count()
        // insight_places 2*3 + session_costs 1*3 + journeys 3*3 + preferences 1*3 (bare hlc also matches \w+)
        // bare hlc_millis is also counted as \w+; so total millis cols via same pattern is 6 groups + 1 row-level = 7 triples = 7 millis
        // But also hlc_millis alone is matched as \w+ includes hlc -> we count via both schema and migration file duplication.
        // Assert at least the expected distinct column definitions exist in schema_full.sql alone.
        val schema = supabaseSchemaText()
        val schemaMillis = Regex("""hlc_millis\s+bigint""", RegexOption.IGNORE_CASE).findAll(schema).count()
        val schemaCounter = Regex("""hlc_counter\s+integer""", RegexOption.IGNORE_CASE).findAll(schema).count()
        val schemaDevice = Regex("""hlc_device_id\s+text""", RegexOption.IGNORE_CASE).findAll(schema).count()
        // 3+1+3+1 = 8 groups => 8 of each column type in the schema (insight_places now 3 with auto_name)
        assertTrue("schema_full.sql must have 8 hlc_millis columns (3+1+3+1 groups), got $schemaMillis", schemaMillis == 8)
        assertTrue("schema_full.sql must have 8 hlc_counter columns, got $schemaCounter", schemaCounter == 8)
        assertTrue("schema_full.sql must have 8 hlc_device_id columns, got $schemaDevice", schemaDevice == 8)
        // Unused to avoid warning
        assertTrue(millisCols >= 8 && counterCols >= 8 && deviceCols >= 8)
    }

    // --- helpers -------------------------------------------------------------

    private fun supabaseSchemaText(): String = supabaseSchemaFile().readText()

    private fun migrationText(): String {
        // Combine both HLC stamp migrations (12120000 and 140000 fix for auto_name)
        val files = listOf(
            "20260902120000_annotation_hlc_stamps.sql",
            "20260902140000_annotation_tiebreak_and_autoname_fix.sql"
        )
        return files.mapNotNull { name ->
            var dir = java.io.File("").absoluteFile
            while (dir.parentFile != null) {
                val c = java.io.File(dir, "supabase/migrations/$name")
                if (c.isFile) return@mapNotNull c.readText()
                dir = dir.parentFile
            }
            val alt = java.io.File("supabase/migrations/$name")
            if (alt.isFile) alt.readText() else null
        }.joinToString("\n")
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
            val candidate = File(dir, "supabase/migrations/20260902120000_annotation_hlc_stamps.sql")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Could not find migration file from ${File("").absolutePath}")
    }

    private fun tableBody(schema: String, table: String): String? {
        return Regex(
            """create table (?:if not exists )?(?:public\.)"?""" + Regex.escape(table) + """"? \((.+?)^\)""",
            setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.MULTILINE, RegexOption.IGNORE_CASE)
        ).find(schema)?.groupValues?.get(1)
    }
}
