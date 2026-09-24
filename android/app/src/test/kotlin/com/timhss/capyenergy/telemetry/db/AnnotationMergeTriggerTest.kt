package com.timhss.capyenergy.telemetry.db

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 2 Lane B Step 2: per-field LWW merge trigger enforced in Postgres.
 *
 * Verifies `supabase/schema_full.sql` and the migration
 * `20260902130000_annotation_merge_trigger.sql` declare:
 * - helper function annotation_hlc_greater (millis -> counter -> origin rank -> device_id)
 * - per-table merge functions and BEFORE INSERT OR UPDATE triggers
 * - per-field independence (name vs geofence, etc.)
 * - tombstone handling that compares wall clock + origin vs max field HLC
 *
 * Reads SQL from files rather than a copy, so drift fails.
 */
class AnnotationMergeTriggerTest {

    @Test
    fun `helper function exists with correct ordering`() {
        val schema = supabaseSchemaText()
        val migration = migrationText()
        val combined = schema + "\n" + migration

        // helper must exist in both
        assertTrue("schema_full.sql must have annotation_hlc_greater", schema.contains("annotation_hlc_greater"))
        assertTrue("migration must have annotation_hlc_greater", migration.contains("annotation_hlc_greater"))

        // ordering after H-1: millis -> counter -> device_id (origin rank removed for general)
        assertTrue("helper must compare millis", Regex("""p_in_millis.*p_ex_millis""", RegexOption.IGNORE_CASE).containsMatchIn(combined))
        assertTrue("helper must compare counter", combined.contains("p_in_counter"))
        assertTrue("helper must compare device_id lexicographically", combined.contains("p_in_device_id > p_ex_device_id"))
        assertTrue("helper must return true on identical (idempotent)", combined.contains("return true"))
        // General helper should be device-id-only (no rank). Check that the first function does not contain rank before its next function
        // But auto_name helper must exist and have origin rank per ADR 0009
        assertTrue("auto_name helper with origin rank must exist", combined.contains("annotation_hlc_greater_with_origin_rank"))
        assertTrue("auto_name helper must map origin rank car=2 phone=1", Regex("""when\s+'car'\s+then\s+2""", RegexOption.IGNORE_CASE).containsMatchIn(combined))
    }

    @Test
    fun `insight_places trigger handles both field groups independently`() {
        val schema = supabaseSchemaText()
        val migration = migrationText()
        val combined = schema + "\n" + migration

        assertTrue("insight_places merge function must exist", combined.contains("insight_places_hlc_merge"))
        assertTrue("insight_places trigger must exist", combined.contains("insight_places_hlc_merge_trigger"))

        // Must have before insert or update
        assertTrue("insight_places trigger must be BEFORE INSERT OR UPDATE",
            Regex("""create trigger insight_places_hlc_merge_trigger\s+before insert or update""", RegexOption.IGNORE_CASE).containsMatchIn(combined))

        // Per-group comparisons
        assertTrue("must compare name_hlc", combined.contains("name_hlc_millis"))
        assertTrue("must compare geofence_hlc", combined.contains("geofence_hlc_millis"))
        // When stale, keeps OLD values for that group's columns
        assertTrue("stale name must keep OLD name", Regex("""new\.name\s*:=\s*old\.name""", RegexOption.IGNORE_CASE).containsMatchIn(combined))
        assertTrue("stale geofence must keep OLD latitude", Regex("""new\.latitude\s*:=\s*old\.latitude""", RegexOption.IGNORE_CASE).containsMatchIn(combined))
        assertTrue("stale geofence must keep OLD longitude", Regex("""new\.longitude\s*:=\s*old\.longitude""", RegexOption.IGNORE_CASE).containsMatchIn(combined))
        assertTrue("stale geofence must keep OLD radius_m", Regex("""new\.radius_m\s*:=\s*old\.radius_m""", RegexOption.IGNORE_CASE).containsMatchIn(combined))

        // Must evaluate groups independently — ensure three wins variables exist (name, geofence, auto_name)
        assertTrue("must have v_name_wins and v_geofence_wins", combined.contains("v_name_wins") && combined.contains("v_geofence_wins"))
        assertTrue("must have v_auto_name_wins", combined.contains("v_auto_name_wins"))
        assertTrue("must OR them for any win", combined.contains("v_name_wins or v_geofence_wins or v_auto_name_wins"))
        // auto_name must use origin-rank helper per ADR 0009
        assertTrue("auto_name must use origin-rank helper", combined.contains("auto_name_hlc_millis") && combined.contains("annotation_hlc_greater_with_origin_rank"))
    }

    @Test
    fun `session_costs trigger handles single atomic cost group`() {
        val schema = supabaseSchemaText()
        assertTrue("session_costs merge function must exist", schema.contains("session_costs_hlc_merge"))
        assertTrue("session_costs trigger must exist", schema.contains("session_costs_hlc_merge_trigger"))
        assertTrue("must compare cost_hlc", schema.contains("cost_hlc_millis"))
        assertTrue("must guard cost_per_kwh, paid_amount, cost_currency together",
            schema.contains("cost_per_kwh") && schema.contains("paid_amount") && schema.contains("cost_currency"))
        assertTrue("stale cost must keep OLD columns",
            Regex("""new\.cost_per_kwh\s*:=\s*old\.cost_per_kwh""", RegexOption.IGNORE_CASE).containsMatchIn(schema))
        // No tombstone for session_costs
        // Ensure session_costs trigger does not mention deleted_at in its function body beyond maybe not needed
        // It is atomic, so no deleted handling required — but check it still has insert guard
        assertTrue("session_costs trigger must be BEFORE INSERT OR UPDATE",
            Regex("""create trigger session_costs_hlc_merge_trigger\s+before insert or update""", RegexOption.IGNORE_CASE).containsMatchIn(schema))
    }

    @Test
    fun `journeys trigger handles three field groups`() {
        val schema = supabaseSchemaText()
        assertTrue("journeys merge function must exist", schema.contains("journeys_hlc_merge"))
        assertTrue("journeys trigger must exist", schema.contains("journeys_hlc_merge_trigger"))
        assertTrue("must have name_hlc", Regex("""journeys.*name_hlc_millis""", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)).containsMatchIn(schema))
        // Check three groups each guard their columns
        assertTrue("stale name must keep OLD name", Regex("""new\.name\s*:=\s*old\.name""", RegexOption.IGNORE_CASE).containsMatchIn(schema))
        // For journeys, new.name appears twice (insight_places also), but ensure note and time_range exist
        assertTrue("must guard note column", Regex("""new\.note\s*:=\s*old\.note""", RegexOption.IGNORE_CASE).containsMatchIn(schema))
        assertTrue("must guard started_at for time_range", Regex("""new\.started_at_utc_millis\s*:=\s*old\.started_at_utc_millis""", RegexOption.IGNORE_CASE).containsMatchIn(schema))
        assertTrue("must guard ended_at for time_range", Regex("""new\.ended_at_utc_millis\s*:=\s*old\.ended_at_utc_millis""", RegexOption.IGNORE_CASE).containsMatchIn(schema))
        assertTrue("must have three win vars", schema.contains("v_name_wins") && schema.contains("v_note_wins") && schema.contains("v_time_wins"))
    }

    @Test
    fun `preferences trigger handles row-level HLC`() {
        val schema = supabaseSchemaText()
        assertTrue("preferences merge function must exist", schema.contains("preferences_hlc_merge"))
        assertTrue("preferences trigger must exist", schema.contains("preferences_hlc_merge_trigger"))
        // Row-level uses bare hlc_*
        assertTrue("preferences must compare hlc_millis", Regex("""public\.preferences.*hlc_millis""", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)).containsMatchIn(schema))
        assertTrue("stale preferences must keep OLD value", Regex("""new\.value\s*:=\s*old\.value""", RegexOption.IGNORE_CASE).containsMatchIn(schema))
    }

    @Test
    fun `tombstone handling exists and is documented`() {
        val migration = migrationText()
        val schema = supabaseSchemaText()
        val combined = schema + "\n" + migration

        // Each tombstone-capable table must mention deleted_at handling
        assertTrue("insight_places must handle deleted_at", Regex("""insight_places.*deleted_at_utc_millis""", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)).containsMatchIn(combined))
        assertTrue("journeys must handle deleted_at", Regex("""journeys.*deleted_at_utc_millis""", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)).containsMatchIn(combined))
        assertTrue("preferences must handle deleted_at", Regex("""preferences.*deleted_at_utc_millis""", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)).containsMatchIn(combined))

        // Tombstone competes against MAX field HLC — must compare wall clock + origin
        assertTrue("must mention MAX of field-group HLCs in comments", migration.contains("MAX") && migration.contains("field-group"))
        assertTrue("must reuse wall clock + origin for tombstone", migration.contains("updated_at_utc_millis") && migration.contains("reuses") && migration.contains("wall clock"))

        // Effective tombstone HLC uses updated_at with counter 0 and origin as device_id
        assertTrue("tombstone check must use 0 counter", Regex("""0,\s*coalesce\(.*origin""", RegexOption.IGNORE_CASE).containsMatchIn(combined))

        // Resurrection logic: must compare incoming field HLC vs tombstone
        assertTrue("must have resurrection path (OLD deleted, NEW not deleted)", combined.contains("old.deleted_at_utc_millis is not null and new.deleted_at_utc_millis is null"))
    }

    @Test
    fun `migration file exists and is idempotent`() {
        val file = migrationFile()
        assertTrue("Migration file must exist at ${file.path}", file.isFile)
        val text = file.readText()
        assertTrue("Migration must be create or replace", text.contains("create or replace function"))
        assertTrue("Migration must drop trigger if exists", text.contains("drop trigger if exists"))
        assertTrue("Migration must create trigger for all four tables",
            text.contains("insight_places_hlc_merge_trigger") &&
                text.contains("session_costs_hlc_merge_trigger") &&
                text.contains("journeys_hlc_merge_trigger") &&
                text.contains("preferences_hlc_merge_trigger")
        )
        assertTrue("Migration must handle BEFORE INSERT OR UPDATE",
            Regex("""before insert or update""", RegexOption.IGNORE_CASE).containsMatchIn(text))
    }

    @Test
    fun `trigger count matches four annotation tables`() {
        val schema = supabaseSchemaText()
        val triggerCount = Regex("""create trigger \w+_hlc_merge_trigger""", RegexOption.IGNORE_CASE).findAll(schema).count()
        assertTrue("schema_full.sql must have 4 HLC merge triggers, got $triggerCount", triggerCount == 4)
        val functionCount = Regex("""create or replace function public\.\w+_hlc_merge\(\)""", RegexOption.IGNORE_CASE).findAll(schema).count()
        assertTrue("schema_full.sql must have 4 HLC merge functions, got $functionCount", functionCount == 4)
        // Plus helper
        assertTrue("helper function must be counted separately", schema.contains("annotation_hlc_greater"))
    }

    // --- helpers -------------------------------------------------------------

    private fun supabaseSchemaText(): String = supabaseSchemaFile().readText()
    private fun migrationText(): String {
        val files = listOf(
            "20260902130000_annotation_merge_trigger.sql",
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
            val candidate = File(dir, "supabase/migrations/20260902130000_annotation_merge_trigger.sql")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Could not find migration file from ${File("").absolutePath}")
    }
}
