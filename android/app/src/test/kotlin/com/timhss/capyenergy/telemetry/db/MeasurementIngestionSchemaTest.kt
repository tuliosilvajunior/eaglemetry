package com.timhss.capyenergy.telemetry.db

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 1 Step 1: the five measurement tables must be ingestible from the
 * car and from the companion under the same natural keys.
 *
 * Two invariants are checked here and nowhere else:
 *
 *  1. `supabase/schema_full.sql` declares the intended primary key for each of
 *     the five tables. That key is what `CloudSink.upsert(..., conflictColumns)`
 *     resolves against, and a mismatch would silently overwrite a different row.
 *  2. The car's `toExportRow()` map, once snake_cased, is a subset of the
 *     cloud's columns. A field renamed in Room without a matching migration is
 *     a column the cloud does not have, and PostgREST answers 42703.
 *
 * The test reads the schema from the file rather than a copy, so a later
 * migration is seen without restating it.
 */
class MeasurementIngestionSchemaTest {

    private fun snakeCase(name: String): String =
        name.replace(Regex("(?<!^)(?=[A-Z])"), "_").lowercase()

    // --- 1. Supabase primary keys are the natural keys -----------------------

    @Test
    fun `supabase measurement tables are keyed on natural keys`() {
        val schema = supabaseSchemaText()
        // Extract primary key columns per table from schema_full.sql
        val expected = mapOf(
            "session" to setOf("vehicle_id", "id"),
            "interval" to setOf("vehicle_id", "session_id", "start_utc_millis"),
            "track" to setOf("vehicle_id", "session_id"),
            "telemetry_events" to setOf(
                "vehicle_id",
                "occurred_at_utc_millis",
                "occurred_at_elapsed_nanos",
                "type",
                "signal_id"
            ),
            "battery_cycles" to setOf("vehicle_id", "start_utc_millis")
        )
        for ((table, want) in expected) {
            val got = primaryKeyColumns(schema, table)
            assertEquals(
                "Supabase table `$table` must be keyed on ${want.sorted()} but was ${got?.sorted()}",
                want,
                got
            )
        }
        // battery_cycles must NOT be keyed on ordinal: ordinal is a ledger
        // position that renumbers, start_utc_millis is the cycle's identity
        // (20260831120000_battery_cycles_key_on_start_time).
        val batteryPk = primaryKeyColumns(schema, "battery_cycles")!!
        assertFalse(
            "battery_cycles key must not contain ordinal (use start_utc_millis)",
            "ordinal" in batteryPk
        )
    }

    // --- 2. Export rows land inside the cloud columns ------------------------

    @Test
    fun `every exported measurement field maps to a cloud column`() {
        val cloudColumns = cloudColumnsByTable(supabaseSchemaText())
        // Helper: assert exported snake_case keys ⊆ cloud columns for that table
        fun assertSubset(table: String, export: Map<String, Any?>) {
            val cloud = cloudColumns[table]
                ?: error("Cloud table `$table` not found in schema_full.sql")
            val missing = export.keys.map { snakeCase(it) }.filter { it !in cloud }
            assertTrue(
                "Export keys for `$table` have no cloud column: $missing. Cloud has ${cloud.sorted()}",
                missing.isEmpty()
            )
        }

        // Session fixture: minimal valid closed TRIP
        val session = SessionEntity(
            id = "sess-1",
            vehicleId = "VIN1",
            kind = "TRIP",
            status = "CLOSED",
            startedAtUtcMillis = 1_750_000_000_000L,
            startedAtElapsedNanos = 10L,
            updatedAtUtcMillis = 1_750_000_000_001L,
            createdAtUtcMillis = 1_750_000_000_000L
        )
        val sessionExport = session.toExportRow()
        assertFalse("dirty must not be exported", "dirty" in sessionExport)
        assertFalse("rowId must not be exported", "rowId" in sessionExport)
        assertSubset("session", sessionExport)
        // Cloud also carries account_id + uploaded_at which the car adds at upload time
        assertTrue("cloud session must carry account_id", "account_id" in cloudColumns["session"]!!)
        assertTrue("cloud session must carry uploaded_at", "uploaded_at" in cloudColumns["session"]!!)

        // Interval fixture
        val interval = IntervalEntity(
            sessionId = "sess-1",
            startUtcMillis = 1_750_000_000_000L,
            widthMillis = 60_000L,
            tractionWh = 10.0,
            regenWh = 2.0,
            auxiliaryWh = 0.5,
            climateWh = 1.0,
            deliveredWh = 3.0,
            distanceKm = 0.8,
            coveredSeconds = 60.0,
            climateCoveredSeconds = 60.0,
            speedCoveredSeconds = 60.0,
            deliveredCoveredSeconds = 0.0,
            startSoc = 80.0,
            endSoc = 79.5,
            startVoltage = 350.0,
            endVoltage = 349.0,
            updatedAtUtcMillis = 1_750_000_000_001L
        )
        val intervalExport = interval.toExportRow()
        assertFalse("dirty must not be exported", "dirty" in intervalExport)
        assertSubset("interval", intervalExport)

        // Track fixture
        val track = TrackEntity(
            sessionId = "sess-1",
            encodingVersion = 1,
            pointCount = 2,
            t = "[0,60000]",
            path = "abcd",
            speed = "[10,12]",
            alt = "[100,101]",
            updatedAtUtcMillis = 1_750_000_000_001L
        )
        val trackExport = track.toExportRow()
        assertFalse("dirty must not be exported", "dirty" in trackExport)
        assertSubset("track", trackExport)

        // Telemetry event fixture: rowid is local, natural key is time+type+signal
        val event = TelemetryEventEntity(
            id = 42L,
            type = "CHARGE_STARTED",
            occurredAtUtcMillis = 1_750_000_000_000L,
            occurredAtElapsedNanos = 123L,
            sourceTimestampNanos = 120L,
            timestampAccuracy = "PRECISE",
            uncertaintyMillis = 50L,
            signalId = "CHARGE_STATE",
            value = "CHARGING",
            previousValue = "IDLE",
            quality = "GOOD",
            source = "VHAL",
            details = "{}",
            sessionId = "sess-1"
        )
        val eventExport = event.toMap()
        assertFalse("dirty must not be exported", "dirty" in eventExport)
        // The car's `id` is an autoincrement rowid and must not be the cloud key.
        // Cloud upsert keeps the same natural key the companion already uses.
        assertTrue("event export must carry id for cursor compat", "id" in eventExport)
        // But the natural key columns must be present and map to cloud
        val eventNaturalKeys = setOf(
            "occurredAtUtcMillis",
            "occurredAtElapsedNanos",
            "type",
            "signalId"
        )
        for (k in eventNaturalKeys) assertTrue("event export must include $k", k in eventExport)
        // Validate the snake_cased subset (excluding id which maps to no cloud PK column directly)
        val eventCloudRelevant = eventExport.filterKeys { it != "id" }
        assertSubset("telemetry_events", eventCloudRelevant)

        // Battery cycle fixture: ordinal is payload but start time is the key
        val cycle = BatteryCycleEntity(
            ordinal = 120L,
            startUtcMillis = 1_750_000_000_000L,
            endUtcMillis = 1_750_000_360_000L,
            dischargePercent = 100.0,
            distanceKm = 42.0,
            tripEnergyKwh = 12.0,
            parkedEnergyKwh = 0.5,
            parkedSocPercent = 2.0,
            cost = 3.5,
            costCurrency = "BRL",
            pricedEnergyKwh = 10.0,
            unpricedEnergyKwh = 2.0,
            isOpen = false,
            isPartial = false,
            energyIncomplete = false,
            mixedCurrency = false,
            openingPricedFraction = 1.0,
            openingBlendedPrice = 0.8,
            frozenAtUtcMillis = null,
            createdAtUtcMillis = 1_750_000_000_000L,
            updatedAtUtcMillis = 1_750_000_000_001L
        )
        val cycleExport = cycle.toExportRow()
        assertFalse("dirty must not be exported", "dirty" in cycleExport)
        assertTrue("cycle export must carry ordinal as ledger position", "ordinal" in cycleExport)
        assertTrue("cycle export must carry startUtcMillis as natural key", "startUtcMillis" in cycleExport)
        assertSubset("battery_cycles", cycleExport)
    }

    // --- 3. Conflict columns the uploader would use --------------------------

    @Test
    fun `expected conflict columns match supabase primary keys`() {
        // These are the exact `conflictColumns` the companion's CloudUploader
        // passes to Supabase (cloud_uploader.dart). The car must use the same
        // keys when it uploads directly, so they are pinned here as a contract.
        val expectedConflict = mapOf(
            "session" to listOf("vehicle_id", "id"),
            "interval" to listOf("vehicle_id", "session_id", "start_utc_millis"),
            "track" to listOf("vehicle_id", "session_id"),
            "telemetry_events" to listOf(
                "vehicle_id",
                "occurred_at_utc_millis",
                "occurred_at_elapsed_nanos",
                "type",
                "signal_id"
            ),
            "battery_cycles" to listOf("vehicle_id", "start_utc_millis")
        )
        val schema = supabaseSchemaText()
        for ((table, conflict) in expectedConflict) {
            val pk = primaryKeyColumns(schema, table)!!
            assertEquals(
                "Conflict columns for `$table` must equal its Supabase primary key",
                pk.sorted(),
                conflict.sorted()
            )
        }
    }

    // --- 4. Car-direct payload fixtures (no rowid, snake_case, idempotent) ---

    @Test
    fun `car payload fixtures serialize under natural keys without local rowids`() {
        // Build one of each entity via toExportRow, snake_case, and augment with
        // vehicle_id/account_id as the car uploader would.
        fun toSinkRow(export: Map<String, Any?>, vehicleId: String, accountId: String): MutableMap<String, Any?> {
            val snake = export.entries.associate { (k, v) -> snakeCase(k) to v }.toMutableMap()
            snake["vehicle_id"] = vehicleId
            snake["account_id"] = accountId
            return snake
        }

        val vehicleId = "VIN-CAR-1"
        val accountId = "00000000-0000-4000-a000-000000000001"

        val session = SessionEntity(
            id = "car-sess-1",
            vehicleId = vehicleId,
            kind = "TRIP",
            status = "CLOSED",
            startedAtUtcMillis = 1_750_000_000_000L,
            startedAtElapsedNanos = 1L,
            createdAtUtcMillis = 1_750_000_000_000L,
            updatedAtUtcMillis = 1_750_000_000_100L
        )
        val sessionRow = toSinkRow(session.toExportRow(), vehicleId, accountId)
        assertEquals(vehicleId, sessionRow["vehicle_id"])
        assertEquals("car-sess-1", sessionRow["id"])
        assertFalse("sink row must not carry dirty", "dirty" in sessionRow)
        assertFalse("sink row must not carry rowId", "rowId" in sessionRow || "row_id" in sessionRow)

        val interval = IntervalEntity(
            sessionId = "car-sess-1",
            startUtcMillis = 1_750_000_000_000L
        )
        val intervalRow = toSinkRow(interval.toExportRow(), vehicleId, accountId)
        intervalRow["session_id"] = "car-sess-1" // uploader adds via session lookup; retain explicit
        assertEquals(vehicleId, intervalRow["vehicle_id"])
        assertEquals(1_750_000_000_000L, intervalRow["start_utc_millis"])

        val track = TrackEntity(
            sessionId = "car-sess-1",
            encodingVersion = 1,
            pointCount = 1,
            t = "[0]",
            path = "abc",
            speed = "[0]",
            alt = "[0]"
        )
        val trackRow = toSinkRow(track.toExportRow(), vehicleId, accountId)
        assertEquals(vehicleId, trackRow["vehicle_id"])
        assertEquals("car-sess-1", trackRow["session_id"])

        val event = TelemetryEventEntity(
            type = "GEAR_CHANGED",
            occurredAtUtcMillis = 1_750_000_000_100L,
            occurredAtElapsedNanos = 999L,
            sourceTimestampNanos = null,
            timestampAccuracy = "ESTIMATED",
            uncertaintyMillis = 1000L,
            signalId = "GEAR",
            value = "D",
            previousValue = "P",
            quality = null,
            source = null,
            details = "{}",
            sessionId = "car-sess-1"
        )
        val eventRow = toSinkRow(event.toMap().filterKeys { it != "id" }, vehicleId, accountId)
        // signal_id '' default for null is handled by companion; car should send '' not null
        if (eventRow["signal_id"] == null) eventRow["signal_id"] = ""
        assertEquals(vehicleId, eventRow["vehicle_id"])
        assertEquals("GEAR_CHANGED", eventRow["type"])

        val cycle = BatteryCycleEntity(
            ordinal = 5L,
            startUtcMillis = 1_750_000_000_000L,
            endUtcMillis = 1_750_000_100_000L,
            dischargePercent = 100.0,
            distanceKm = 10.0,
            tripEnergyKwh = 2.0,
            parkedEnergyKwh = 0.1,
            parkedSocPercent = 1.0,
            cost = null,
            costCurrency = null,
            pricedEnergyKwh = 0.0,
            unpricedEnergyKwh = 2.0,
            isOpen = false,
            isPartial = false,
            energyIncomplete = false,
            mixedCurrency = false,
            openingPricedFraction = 0.0,
            openingBlendedPrice = 0.0,
            frozenAtUtcMillis = null,
            createdAtUtcMillis = 1_750_000_000_000L,
            updatedAtUtcMillis = 1_750_000_000_100L
        )
        val cycleRow = toSinkRow(cycle.toExportRow(), vehicleId, accountId)
        assertEquals(vehicleId, cycleRow["vehicle_id"])
        assertEquals(1_750_000_000_000L, cycleRow["start_utc_millis"])
        // The ordinal stays in the payload even though it is not the key
        assertEquals(5L, cycleRow["ordinal"])

        // Idempotency: two payloads with same natural key differ only in non-key fields
        val sessionRow2 = toSinkRow(session.copy(rollupDistanceKm = 12.3).toExportRow(), vehicleId, accountId)
        assertEquals(sessionRow["vehicle_id"], sessionRow2["vehicle_id"])
        assertEquals(sessionRow["id"], sessionRow2["id"])

        val cycleRow2 = toSinkRow(cycle.copy(dischargePercent = 101.0).toExportRow(), vehicleId, accountId)
        assertEquals(cycleRow["vehicle_id"], cycleRow2["vehicle_id"])
        assertEquals(cycleRow["start_utc_millis"], cycleRow2["start_utc_millis"])
    }

    // --- 5. Car direct upload: nullable account_id + server-side stamp -------
    //
    // Issue #236 Phase 1. The car uploads before any account claims the
    // vehicle, so every table that denormalizes ownership must accept a NULL
    // `account_id`, and the column must be stamped by the server rather than by
    // the payload. These three tests pin the cloud contract the car's uploader
    // will be written against, so a later edit to `schema_full.sql` that takes
    // any of it away fails here rather than in the car.

    private val measurementTables = listOf(
        "session",
        "interval",
        "track",
        "telemetry_events",
        "trip_segments",
        "battery_cycles",
        "battery_cycle_sessions"
    )

    @Test
    fun `account_id is nullable on the vehicle and on every measurement table`() {
        val schema = supabaseSchemaText()
        for (table in measurementTables + listOf("vehicle", "vehicle_devices", "session_costs")) {
            val body = tableBody(schema, table)
                ?: error("Table `$table` not found in schema_full.sql")
            val decl = body.lines().firstOrNull { it.trim().startsWith("account_id ") }
                ?: error("Table `$table` has no account_id column")
            assertFalse(
                "`$table`.account_id must be nullable: the car uploads before a claim " +
                    "(20260903120000). Declaration was: ${decl.trim()}",
                decl.contains("not null", ignoreCase = true)
            )
        }
        // The annotation tables that are phone-only stay required.
        for (table in listOf("insight_places", "preferences", "journeys")) {
            val body = tableBody(schema, table) ?: error("Table `$table` not found")
            val decl = body.lines().first { it.trim().startsWith("account_id ") }
            assertTrue(
                "`$table`.account_id must stay not null: it is written only by the phone",
                decl.contains("not null", ignoreCase = true)
            )
        }
    }

    @Test
    fun `every measurement table carries the server-side account stamp trigger`() {
        val schema = supabaseSchemaText()
        assertTrue(
            "schema_full.sql must define stamp_measurement_account_id()",
            schema.contains("create or replace function public.stamp_measurement_account_id()")
        )
        // SECURITY INVOKER is load-bearing: a SECURITY DEFINER body reports the
        // definer in current_user, so the privileged-writer branch would match
        // on every request and the stamp would never run.
        val fn = schema.substringAfter("create or replace function public.stamp_measurement_account_id()")
            .substringBefore("$$;")
        val fnHeader = fn.substringBefore("as $$")
        assertFalse(
            "stamp_measurement_account_id must not be SECURITY DEFINER",
            fnHeader.contains("security definer", ignoreCase = true)
        )
        assertTrue(
            "the stamp must derive from the device token",
            fn.contains("car_device_identity_from_header()")
        )
        assertTrue("the stamp must fall back to auth.uid()", fn.contains("auth.uid()"))

        // The trigger is installed by a loop over the table names; the list in
        // that loop is the contract.
        val loop = schema.substringAfter("foreach t in array array[")
            .substringBefore("]")
        for (table in measurementTables) {
            assertTrue(
                "`$table` must be in the measurement_account_stamp trigger loop",
                loop.contains("'$table'")
            )
        }
        assertTrue(
            "the trigger must fire before insert or update",
            schema.contains("create trigger measurement_account_stamp before insert or update")
        )
    }

    @Test
    fun `the car reaches every measurement table as anon, scoped to its own vehicle`() {
        val schema = supabaseSchemaText()
        for (table in measurementTables) {
            val ref = if (table == "interval") "public.\"interval\"" else "public.$table"
            for (suffix in listOf("device_reads", "device_writes")) {
                assertTrue(
                    "schema_full.sql must declare policy ${table}_$suffix on $ref",
                    schema.contains("create policy ${table}_$suffix on $ref")
                )
            }
        }
        // Issue 236 supersedes issue 227's measurement policies by taking their
        // names. Two permissive policies for one verb would be ORed together and
        // the account-scoped one would never be reached, so the older names must
        // not survive under a different spelling.
        for (stale in listOf("_device_uploads", "_device_completes")) {
            assertFalse(
                "no device policy may carry the superseded suffix `$stale`",
                schema.contains(stale)
            )
        }
        // Two halves of the same invariant. The stamp trigger owns *writes* to
        // account_id, so no device policy may test it in a `with check`: the
        // value there is always the one the trigger just derived. But the
        // clauses that see a row already in the table — SELECT, and the
        // `using` half of UPDATE — must test it, or one account's live
        // credential would read and rewrite another account's rows on the same
        // vehicle. Section 6d holds issue 227's annotation policies, which stay
        // account-scoped, so the block stops there.
        val deviceBlock = schema.substringAfter("-- 6c. CAR DIRECT UPLOAD")
            .substringBefore("-- 6d. CAR DEVICE")
            .lines().filterNot { it.trim().startsWith("--") }.joinToString("\n")
        for (check in deviceBlock.split("with check ").drop(1)) {
            assertFalse(
                "a device policy's `with check` must not test account_id; " +
                    "the stamp trigger owns writes to that column",
                check.substringBefore(";").contains("account_id")
            )
        }
        val accountScoped = deviceBlock.split("create policy ").drop(1)
            .filter { it.contains(" for select ") || it.contains(" for update ") }
        assertTrue(
            "the 6c block must declare the device SELECT and UPDATE policies",
            accountScoped.size == 12
        )
        for (policy in accountScoped) {
            assertTrue(
                "a device SELECT/UPDATE policy must bound its `using` clause to " +
                    "the token's account, not to the vehicle alone",
                policy.substringAfter("using ").substringBefore("with check ").contains(
                    "and account_id is not distinct from " +
                        "(car_device_identity_from_header()->>'account_id')::uuid"
                )
            )
        }
        assertTrue(
            "every device policy scopes to the token's vehicle",
            deviceBlock.contains("car_device_identity_from_header()->>'vehicle_id' = vehicle_id")
        )
        // Standing rule: a refusal comes from RLS, never from a missing grant.
        assertTrue(
            "anon must be granted the write verbs on the updatable measurement tables",
            schema.contains(
                "grant select, insert, update, delete on\n" +
                    "  public.vehicle,\n" +
                    "  public.session,\n" +
                    "  public.\"interval\",\n" +
                    "  public.track,\n" +
                    "  public.battery_cycles,\n" +
                    "  public.battery_cycle_sessions\n" +
                    "  to anon;"
            )
        )
        assertTrue(
            "anon must be granted select+insert on the insert-only tables",
            schema.contains(
                "grant select, insert on\n" +
                    "  public.telemetry_events,\n" +
                    "  public.trip_segments\n" +
                    "  to anon;"
            )
        )
    }

    private fun tableBody(schema: String, table: String): String? = Regex(
        """create table (?:if not exists )?(?:public\.)"?""" + Regex.escape(table) + """"? \((.+?)^\)""",
        setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.MULTILINE, RegexOption.IGNORE_CASE)
    ).find(schema)?.groupValues?.get(1)

    // --- parsing helpers -----------------------------------------------------

    private fun supabaseSchemaText(): String = supabaseSchemaFile().readText()

    private fun supabaseSchemaFile(): File {
        var dir = File("").absoluteFile
        while (dir.parentFile != null) {
            val candidate = File(dir, "supabase/schema_full.sql")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Could not find supabase/schema_full.sql from ${File("").absolutePath}")
    }

    private fun primaryKeyColumns(schema: String, table: String): Set<String>? {
        // Find the CREATE TABLE block for `table` and extract primary key (...).
        // Handles `primary key (vehicle_id, id)` and quoted identifiers.
        val tableBlock = Regex(
            """create table (?:if not exists )?(?:public\.)"?""" + Regex.escape(table) + """"? \((.+?)^\)""",
            setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.MULTILINE, RegexOption.IGNORE_CASE)
        ).find(schema)?.groupValues?.get(1) ?: return null
        // Primary key may be inline or table constraint
        val pk = Regex("""primary key\s*\(([^)]+)\)""", RegexOption.IGNORE_CASE).findAll(tableBlock)
            .lastOrNull()?.groupValues?.get(1) ?: return null
        return pk.split(",").map { it.trim().trim('"', '\'', '`').lowercase() }.toSet()
    }

    private fun cloudColumnsByTable(schema: String): Map<String, Set<String>> {
        val result = mutableMapOf<String, MutableSet<String>>()
        // Simple state: iterate CREATE TABLE blocks and collect column names
        val createTable = Regex(
            """create table (?:if not exists )?(?:public\.)"?([a-z_]+)"? \((.+?)^\)""",
            setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.MULTILINE, RegexOption.IGNORE_CASE)
        )
        for (m in createTable.findAll(schema)) {
            val table = m.groupValues[1].lowercase()
            val body = m.groupValues[2]
            val cols = mutableSetOf<String>()
            for (line in body.lines()) {
                val trimmed = line.trim()
                if (trimmed.isEmpty() || trimmed.startsWith("--")) continue
                if (trimmed.startsWith("primary key", ignoreCase = true)) continue
                if (trimmed.startsWith("foreign key", ignoreCase = true)) continue
                if (trimmed.startsWith("constraint", ignoreCase = true)) continue
                // Column def starts with optional quote + name
                val colMatch = Regex("""^"?([a-z_][a-z0-9_]*)"?\s+""", RegexOption.IGNORE_CASE).find(trimmed)
                if (colMatch != null) cols.add(colMatch.groupValues[1].lowercase())
            }
            result[table] = cols
        }
        // Also pick up ALTER TABLE ... ADD COLUMN for incremental columns
        val alter = Regex("""alter table (?:public\.)"?([a-z_]+)"? add column "?([a-z_]+)"?""", RegexOption.IGNORE_CASE)
        for (m in alter.findAll(schema)) {
            val table = m.groupValues[1].lowercase()
            val col = m.groupValues[2].lowercase()
            result.getOrPut(table) { mutableSetOf() }.add(col)
        }
        return result
    }
}
