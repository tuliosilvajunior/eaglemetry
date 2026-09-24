package com.timhss.capyenergy.telemetry.db

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 2 Step 1: device pairing and vehicle ownership schema contract.
 *
 * Verifies `supabase/schema_full.sql` and the migration
 * `20260901120000_device_pairing_and_vehicle_ownership.sql` declare:
 *   - tables `device_pairing_sessions`, `vehicle_ownership`, `vehicle_devices`
 *   - their columns, types, defaults, checks and references
 *   - their primary keys and unique constraints
 *   - their indexes
 *   - Row Level Security enabled with owner-scoped policies
 *
 * Reads SQL from files rather than a copy, so a later migration drift fails.
 */
class DevicePairingSchemaTest {

    @Test
    fun `device_pairing_sessions has correct primary key`() {
        val schema = supabaseSchemaText()
        val pk = primaryKeyColumns(schema, "device_pairing_sessions")
        assertEquals(
            "device_pairing_sessions must be keyed on device_code",
            setOf("device_code"),
            pk
        )
    }

    @Test
    fun `vehicle_ownership has correct primary key`() {
        val schema = supabaseSchemaText()
        val pk = primaryKeyColumns(schema, "vehicle_ownership")
        assertEquals(
            "vehicle_ownership must be keyed on id",
            setOf("id"),
            pk
        )
    }

    @Test
    fun `vehicle_devices has correct primary key`() {
        val schema = supabaseSchemaText()
        val pk = primaryKeyColumns(schema, "vehicle_devices")
        assertEquals(
            "vehicle_devices must be keyed on device_id",
            setOf("device_id"),
            pk
        )
    }

    @Test
    fun `all three tables have RLS enabled`() {
        val schema = supabaseSchemaText()
        for (table in listOf("device_pairing_sessions", "vehicle_ownership", "vehicle_devices")) {
            assertTrue(
                "Table $table must have Row Level Security enabled",
                schema.contains(Regex("""alter table\s+public\.$table\s+enable row level security""", RegexOption.IGNORE_CASE))
            )
        }
        // Also check migration file
        val migration = migrationText()
        for (table in listOf("device_pairing_sessions", "vehicle_ownership", "vehicle_devices")) {
            assertTrue(
                "Migration must enable RLS on $table",
                migration.contains(Regex("""alter table\s+public\.$table\s+enable row level security""", RegexOption.IGNORE_CASE))
            )
        }
    }

    @Test
    fun `device_pairing_sessions columns match spec`() {
        val schema = supabaseSchemaText()
        val body = tableBody(schema, "device_pairing_sessions")
            ?: error("device_pairing_sessions not found in schema_full.sql")
        // device_code uuid primary key default gen_random_uuid()
        assertTrue("device_code must be uuid primary key default gen_random_uuid()", body.contains(Regex("""device_code\s+uuid\s+primary key\s+default\s+gen_random_uuid\(\)""", RegexOption.IGNORE_CASE)))
        // user_code varchar(8) not null
        assertTrue("user_code must be varchar(8) not null", body.contains(Regex("""user_code\s+varchar\s*\(\s*8\s*\)\s+not null""", RegexOption.IGNORE_CASE)))
        // vehicle_id text not null
        assertTrue("vehicle_id must be text not null", body.contains(Regex("""vehicle_id\s+text\s+not null""", RegexOption.IGNORE_CASE)))
        // status text not null check ... default 'pending'
        assertTrue("status must have check constraint and default pending", body.contains(Regex("""status\s+text\s+not null\s+check\s*\(.*pending.*approved.*rejected.*expired.*\)\s*default\s*'pending'""", RegexOption.IGNORE_CASE)))
        // created_at timestamptz not null default now()
        // expires_at timestamptz not null default (now() + interval '5 minutes')
        assertTrue("expires_at must default to now() + interval '5 minutes'", body.contains(Regex("""expires_at\s+timestamptz\s+not null\s+default\s*\(now\(\)\s*\+\s*interval\s*'5 minutes'\)""", RegexOption.IGNORE_CASE)))
        // approved_by uuid references auth.users
        assertTrue("approved_by must reference auth.users", body.contains(Regex("""approved_by\s+uuid\s+references\s+auth\.users""", RegexOption.IGNORE_CASE)))
        assertTrue("approved_by must have on delete set null", body.contains(Regex("""on delete set null""", RegexOption.IGNORE_CASE)))
        // car_token text
        assertTrue("car_token must be text", body.contains(Regex("""car_token\s+text""", RegexOption.IGNORE_CASE)))
    }

    @Test
    fun `vehicle_ownership columns match spec`() {
        val schema = supabaseSchemaText()
        val body = tableBody(schema, "vehicle_ownership")
            ?: error("vehicle_ownership not found in schema_full.sql")
        assertTrue("id must be uuid primary key default gen_random_uuid()", body.contains(Regex("""\bid\s+uuid\s+primary key\s+default\s+gen_random_uuid\(\)""", RegexOption.IGNORE_CASE)))
        assertTrue("vehicle_id must be text not null", body.contains(Regex("""vehicle_id\s+text\s+not null""", RegexOption.IGNORE_CASE)))
        assertTrue("account_id must be uuid not null references auth.users", body.contains(Regex("""account_id\s+uuid\s+not null\s+references\s+auth\.users""", RegexOption.IGNORE_CASE)))
        assertTrue("account_id must have on delete cascade", body.contains(Regex("""on delete cascade""", RegexOption.IGNORE_CASE)))
        assertTrue("created_at must be timestamptz not null default now()", body.contains(Regex("""created_at\s+timestamptz\s+not null\s+default\s+now\(\)""", RegexOption.IGNORE_CASE)))
        assertTrue("revoked_at must be timestamptz", body.contains(Regex("""revoked_at\s+timestamptz""", RegexOption.IGNORE_CASE)))
        assertTrue("must have unique(vehicle_id, account_id)", body.contains(Regex("""unique\s*\(\s*vehicle_id\s*,\s*account_id\s*\)""", RegexOption.IGNORE_CASE)))
    }

    @Test
    fun `vehicle_devices columns match spec`() {
        val schema = supabaseSchemaText()
        val body = tableBody(schema, "vehicle_devices")
            ?: error("vehicle_devices not found in schema_full.sql")
        assertTrue("device_id must be uuid primary key default gen_random_uuid()", body.contains(Regex("""device_id\s+uuid\s+primary key\s+default\s+gen_random_uuid\(\)""", RegexOption.IGNORE_CASE)))
        assertTrue("vehicle_id must be text not null", body.contains(Regex("""vehicle_id\s+text\s+not null""", RegexOption.IGNORE_CASE)))
        // Nullable since 20260903120000 (issue #236): a device credential is
        // account-less until an account claims the vehicle. The reference and
        // its cascade stay, so deleting the claimer still removes the row.
        assertTrue("account_id must be uuid references auth.users", body.contains(Regex("""account_id\s+uuid\s+references\s+auth\.users""", RegexOption.IGNORE_CASE)))
        assertFalse("account_id must be nullable for a pre-claim credential", body.contains(Regex("""account_id\s+uuid\s+not null""", RegexOption.IGNORE_CASE)))
        assertTrue("token_hash must be text not null", body.contains(Regex("""token_hash\s+text\s+not null""", RegexOption.IGNORE_CASE)))
        assertTrue("created_at must be timestamptz not null default now()", body.contains(Regex("""created_at\s+timestamptz\s+not null\s+default\s+now\(\)""", RegexOption.IGNORE_CASE)))
        assertTrue("revoked_at must be timestamptz", body.contains(Regex("""revoked_at\s+timestamptz""", RegexOption.IGNORE_CASE)))
    }

    @Test
    fun `indexes exist as specified`() {
        val schema = supabaseSchemaText()
        val migration = migrationText()
        val combined = "$schema\n$migration"
        // device_pairing_sessions indexes (create index may be split across lines)
        assertTrue("must have index on user_code", combined.contains(Regex("""create index.*on\s+public\.device_pairing_sessions\s*\(\s*user_code\s*\)""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))))
        assertTrue("must have index on (status, expires_at)", combined.contains(Regex("""create index.*on\s+public\.device_pairing_sessions\s*\(\s*status\s*,\s*expires_at\s*\)""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))))
        // vehicle_ownership index on (account_id, vehicle_id)
        assertTrue("must have index on vehicle_ownership(account_id, vehicle_id)", combined.contains(Regex("""create index.*on\s+public\.vehicle_ownership\s*\(\s*account_id\s*,\s*vehicle_id\s*\)""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))))
        // vehicle_devices index on (vehicle_id, token_hash)
        assertTrue("must have index on vehicle_devices(vehicle_id, token_hash)", combined.contains(Regex("""create index.*on\s+public\.vehicle_devices\s*\(\s*vehicle_id\s*,\s*token_hash\s*\)""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))))
    }

    @Test
    fun `policies exist for ownership and devices`() {
        val schema = supabaseSchemaText()
        // At least one policy per table scoped to authenticated
        assertTrue("device_pairing_sessions must have a policy", schema.contains(Regex("""create policy.*on\s+public\.device_pairing_sessions""", RegexOption.IGNORE_CASE)))
        assertTrue("vehicle_ownership must have a policy", schema.contains(Regex("""create policy.*on\s+public\.vehicle_ownership""", RegexOption.IGNORE_CASE)))
        assertTrue("vehicle_devices must have a policy", schema.contains(Regex("""create policy.*on\s+public\.vehicle_devices""", RegexOption.IGNORE_CASE)))
        // Ownership and devices must filter on account_id = auth.uid()
        assertTrue("vehicle_ownership policy must use account_id = auth.uid()", schema.contains(Regex("""vehicle_ownership.*account_id\s*=\s*\(select auth\.uid\(\)\)""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))))
        assertTrue("vehicle_devices policy must use account_id = auth.uid()", schema.contains(Regex("""vehicle_devices.*account_id\s*=\s*\(select auth\.uid\(\)\)""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))))
    }

    @Test
    fun `migration file exists with required tables`() {
        val file = migrationFile()
        assertTrue("Migration file must exist at ${file.path}", file.isFile)
        val text = file.readText()
        assertTrue("Migration must create device_pairing_sessions", text.contains(Regex("""create table.*device_pairing_sessions""", RegexOption.IGNORE_CASE)))
        assertTrue("Migration must create vehicle_ownership", text.contains(Regex("""create table.*vehicle_ownership""", RegexOption.IGNORE_CASE)))
        assertTrue("Migration must create vehicle_devices", text.contains(Regex("""create table.*vehicle_devices""", RegexOption.IGNORE_CASE)))
    }

    @Test
    fun `vehicle_ownership enforces single active owner via partial unique index`() {
        val combined = supabaseSchemaText() + "\n" + migrationText()
        assertTrue(
            "Must have partial unique index vehicle_ownership_single_active_owner_idx where revoked_at is null",
            combined.contains(Regex("""create unique index.*vehicle_ownership_single_active_owner_idx.*where\s+revoked_at\s+is\s+null""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))),
        )
    }

    @Test
    fun `client cannot directly insert ownership or device rows (H3 bypass closed)`() {
        val combined = supabaseSchemaText() + "\n" + migrationText()
        // No authenticated insert policies should exist — claims go through service_role RPC
        assertTrue(
            "vehicle_ownership_owner_inserts policy must not exist",
            !combined.contains(Regex("""create policy\s+vehicle_ownership_owner_inserts""", RegexOption.IGNORE_CASE)),
        )
        assertTrue(
            "vehicle_devices_owner_inserts policy must not exist",
            !combined.contains(Regex("""create policy\s+vehicle_devices_owner_inserts""", RegexOption.IGNORE_CASE)),
        )
        // Grants: authenticated should not have insert on those tables; service_role should
        // Schema uses `grant select, update` to authenticated and `grant select, insert, update` to service_role
        // Also check explicit revoke lines exist
        assertTrue(
            "Must revoke insert from authenticated on vehicle_ownership",
            combined.contains(Regex("""revoke\s+insert\s+on\s+public\.vehicle_ownership\s+from\s+authenticated""", RegexOption.IGNORE_CASE)),
        )
        assertTrue(
            "Must revoke insert from authenticated on vehicle_devices",
            combined.contains(Regex("""revoke\s+insert\s+on\s+public\.vehicle_devices\s+from\s+authenticated""", RegexOption.IGNORE_CASE)),
        )
    }

    @Test
    fun `pairing rate-limit and atomic RPC helpers exist`() {
        val combined = supabaseSchemaText() + "\n" + migrationText()
        assertTrue("Must have pairing_claim_attempts table", combined.contains(Regex("""create table.*pairing_claim_attempts""", RegexOption.IGNORE_CASE)))
        assertTrue("Must have claim_pairing_session function", combined.contains(Regex("""create or replace function.*claim_pairing_session""", RegexOption.IGNORE_CASE)))
        assertTrue("Must have consume_pairing_token function", combined.contains(Regex("""create or replace function.*consume_pairing_token""", RegexOption.IGNORE_CASE)))
        assertTrue("Must have cleanup_expired_pairing_tokens function", combined.contains(Regex("""create or replace function.*cleanup_expired_pairing_tokens""", RegexOption.IGNORE_CASE)))
    }

    // --- helpers -------------------------------------------------------------

    private fun supabaseSchemaText(): String = supabaseSchemaFile().readText()

    private fun migrationText(): String = migrationFile().readText()

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
            val candidate = File(dir, "supabase/migrations/20260901120000_device_pairing_and_vehicle_ownership.sql")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Could not find migration file from ${File("").absolutePath}")
    }

    private fun primaryKeyColumns(schema: String, table: String): Set<String>? {
        val tableBlock = Regex(
            """create table (?:if not exists )?(?:public\.)"?""" + Regex.escape(table) + """"? \((.+?)^\)""",
            setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.MULTILINE, RegexOption.IGNORE_CASE)
        ).find(schema)?.groupValues?.get(1) ?: return null
        // 1. Inline primary key: "device_code uuid primary key ..."
        val inline = Regex("""^\s*"?([a-z_][a-z0-9_]*)"?\s+[^,]*\bprimary key\b""", setOf(RegexOption.MULTILINE, RegexOption.IGNORE_CASE))
            .findAll(tableBlock)
            .map { it.groupValues[1].lowercase() }
            .toSet()
        if (inline.isNotEmpty()) return inline
        // 2. Table constraint: primary key (...)
        val pk = Regex("""primary key\s*\(([^)]+)\)""", RegexOption.IGNORE_CASE).findAll(tableBlock)
            .lastOrNull()?.groupValues?.get(1) ?: return null
        return pk.split(",").map { it.trim().trim('"', '\'', '`').lowercase() }.toSet()
    }

    private fun tableBody(schema: String, table: String): String? {
        return Regex(
            """create table (?:if not exists )?(?:public\.)"?""" + Regex.escape(table) + """"? \((.+?)^\)""",
            setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.MULTILINE, RegexOption.IGNORE_CASE)
        ).find(schema)?.groupValues?.get(1)
    }
}
