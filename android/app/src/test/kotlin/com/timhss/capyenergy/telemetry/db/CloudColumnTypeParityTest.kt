package com.timhss.capyenergy.telemetry.db

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A column the car calls a boolean is a boolean in the cloud too.
 *
 * The cloud schema in `supabase/migrations/` was generated from Room's exported
 * schema, which reports a **storage affinity** rather than a type. SQLite has no
 * boolean and stores one as INTEGER, so the generator wrote `bigint` for five
 * columns whose Kotlin field says `Boolean`. `toExportRow()` then puts `true` in
 * the map, the sync carries it unchanged, and PostgREST refuses it with `22P02`.
 *
 * That is what the phone's first real upload hit on 2026-08-20: `22P02 ·
 * session · 23`. Nothing in Kotlin, in Dart or in SQL was wrong on its own —
 * the two halves simply disagreed about one type, and no test compared them.
 * This one does.
 *
 * It reads the SQL rather than a copy of it, so a column added to the cloud in a
 * later migration is seen here without anything being restated.
 */
class CloudColumnTypeParityTest {

    private val booleanField = Regex("""\bval\s+([A-Za-z][A-Za-z0-9]*)\s*:\s*Boolean\b""")

    private val tableName = Regex("""tableName\s*=\s*"([a-z_]+)"""")

    /** `isOpen` is `is_open`, the same transform the uploader applies. */
    private fun snakeCase(name: String) =
        name.replace(Regex("(?<!^)(?=[A-Z])"), "_").lowercase()

    @Test
    fun `every boolean column of an entity is a boolean in the cloud`() {
        val cloud = cloudBooleanColumns()
        assertTrue(
            "No boolean column was found in supabase/migrations; the sweep " +
                "would pass while proving nothing",
            cloud.isNotEmpty()
        )

        val cloudTables = cloudTables()
        val offenders = mutableListOf<String>()
        entityFiles().forEach { file ->
            val text = file.readText()
            // Only what the cloud actually holds. `telemetry_frames` is the
            // retired frame table: it still exists on the car and in the sync,
            // and it has no cloud table, so its columns have nothing there to
            // agree with.
            val table = tableName.find(text)?.groupValues?.get(1)
            if (table == null || table !in cloudTables) return@forEach
            booleanField.findAll(text).forEach { match ->
                val field = match.groupValues[1]
                // A computed `val isDeleted: Boolean get() = ...` is not a
                // column. Room only persists a field with no getter.
                val tail = text.substring(match.range.last + 1).trimStart()
                if (tail.startsWith("get(")) return@forEach
                // The pending-upload mark is the car's own bookkeeping: it
                // never enters a `toExportRow()`, so the sync never carries
                // it and the cloud holds no such column to agree with.
                if (field == "dirty") return@forEach
                val column = snakeCase(field)
                if (column !in cloud) {
                    offenders += "${file.name}.$field -> $column"
                }
            }
        }

        assertTrue(
            "These columns are Boolean in Kotlin and are not boolean in the " +
                "cloud. The car sends `true`; Postgres answers 22P02: $offenders",
            offenders.isEmpty()
        )
    }

    private fun entityFiles(): List<File> =
        File(sourceRoot(), "main/kotlin/com/timhss/capyenergy/telemetry/db")
            .listFiles()
            .orEmpty()
            .filter { it.isFile && it.name.endsWith("Entity.kt") }

    /** Every table the cloud holds. */
    private fun cloudTables(): Set<String> {
        val created = Regex("""create table (?:public\.)?"?([a-z_]+)"?""")
        val tables = mutableSetOf<String>()
        migrationsDir().listFiles().orEmpty()
            .filter { it.isFile && it.extension == "sql" }
            .forEach { file ->
                created.findAll(file.readText()).forEach { tables += it.groupValues[1] }
            }
        return tables
    }

    /** Every column the migrations declare, or later alter, as `boolean`. */
    private fun cloudBooleanColumns(): Set<String> {
        val declared = Regex("""^\s*([a-z_]+)\s+boolean\b""", RegexOption.MULTILINE)
        val altered = Regex("""alter\s+column\s+([a-z_]+)\s+type\s+boolean""")
        val columns = mutableSetOf<String>()
        migrationsDir().listFiles().orEmpty()
            .filter { it.isFile && it.extension == "sql" }
            .forEach { file ->
                val sql = file.readText()
                declared.findAll(sql).forEach { columns += it.groupValues[1] }
                altered.findAll(sql).forEach { columns += it.groupValues[1] }
            }
        return columns
    }

    private fun migrationsDir(): File {
        var dir = File("").absoluteFile
        while (dir.parentFile != null) {
            val candidate = File(dir, "supabase/migrations")
            if (candidate.isDirectory) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException(
            "Could not find supabase/migrations from ${File("").absolutePath}"
        )
    }

    private fun sourceRoot(): File {
        var dir = File("").absoluteFile
        while (dir.parentFile != null) {
            val candidate = File(dir, "app/src")
            if (candidate.isDirectory) return candidate
            val here = File(dir, "src")
            if (here.isDirectory && File(here, "main/kotlin").isDirectory) return here
            dir = dir.parentFile
        }
        throw IllegalStateException("Could not find app/src from ${File("").absolutePath}")
    }
}
