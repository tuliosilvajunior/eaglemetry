package com.timhss.capyenergy.telemetry.db

import java.io.File
import com.timhss.capyenergy.telemetry.EnergyBucket
import com.timhss.capyenergy.telemetry.toEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The structural birth-point guarantee (`gb236-p4` step 1, review pass 2).
 *
 * Every table that carries an `accountId` column must have every row born
 * owned — a row must be stamped at the moment its entity is constructed in
 * production code, never by a later pass. This test walks every production
 * `.kt` file under `telemetry/` and finds every construction of an entity
 * that owns an account column. Each such construction must either pass
 * `accountId` or stand in the explicit allow-list below; an unknown
 * construction site fails the build.
 *
 * The allow-list is deliberately small and every entry has a reason:
 *
 *  - the migration DDL (`TelemetryDatabase`) — the migration must land rows
 *    null (that is the adoption contract), and
 *    `restorePreservedPlaces` carries the row's own stored stamp through;
 *  - the entity *declarations* (the `data class` head) — not a birth;
 *  - `IntervalReconciler`'s pure remap — it `copy()`s existing rows, so the
 *    stamp travels with the row.
 *
 * Any other construction — a new repository write, a revived merge-incoming
 * path, a future import — must stamp explicitly or this test fails, so a
 * fourth (or fifth) hole cannot slip through unnoticed.
 */
class LocalAccountStampBirthPointsTest {

    /**
     * The ownable entities are discovered, not listed. The schema export
     * `45.json` records which tables carry an `accountId` column (the Room
     * compiler wrote it from the entity `@Entity` declarations); the test
     * reads that file, so the set is exactly "everything that has an account
     * column" today — including a table a future migration adds. The table
     * name maps to the entity class by scanning the entity files for their
     * `@Entity(tableName = ...)` declaration. If someone adds a new table
     * with `accountId` and forgets to stamp its births, the scan discovers it
     * and fails.
     */
    private val ownableEntities: List<String> by lazy { discoverOwnableEntities() }

    private fun discoverOwnableEntities(): List<String> {
        val schema = latestSchemaJson().readText()
        // Room's exported schema is JSON; a table owns an account column when
        // its entity field list contains a column named accountId. The whole
        // table body is parsed, so a table with the column is discovered even
        // if it was added by a future migration.
        val tableWithAccount = mutableListOf<String>()
        val tableRe = Regex("\"tableName\"\\s*:\\s*\"([a-z_]+)\"")
        val fieldNameRe = Regex("\"columnName\"\\s*:\\s*\"([A-Za-z_]+)\"")
        val tableSpans = tableRe.findAll(schema).toList()
        for (i in tableSpans.indices) {
            val table = tableSpans[i].groupValues[1]
            val start = tableSpans[i].range.last
            val end = if (i + 1 < tableSpans.size) tableSpans[i + 1].range.first else schema.length
            val body = schema.substring(start, end)
            if (fieldNameRe.findAll(body).any { it.groupValues[1] == "accountId" }) {
                tableWithAccount += table
            }
        }
        // Map each table to its owning entity class from the @Entity
        // declarations in production sources.
        val entityClassByTable = mutableMapOf<String, String>()
        for (file in productionFiles()) {
            val text = file.readText()
            val table = Regex("(?s)@Entity\\s*\\(.*?tableName\\s*=\\s*\"([a-z_]+)\"")
                .find(text)?.groupValues?.get(1) ?: continue
            val klass = Regex("\\bdata class (\\w+Entity)\\b").find(text)?.groupValues?.get(1) ?: continue
            entityClassByTable[table] = klass
        }
        return tableWithAccount.mapNotNull { entityClassByTable[it] }.distinct()
    }

    private fun latestSchemaJson(): File {

        // The test runs with CWD = the Gradle module dir (android/app), but
        // also works from the repo root: check the relative path first.
        val module = File("schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase")
        val root = File("android/app/schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase")
        val dir = listOf(module, root).firstOrNull { it.isDirectory }
            ?: error("schema export directory not found")
        return dir.listFiles { f -> f.name.endsWith(".json") }!!.maxBy { it.name.substringBefore(".json").toInt() }
    }

    @Test
    fun `every production construction of an ownable entity stamps its account`() {
        val failures = mutableListOf<String>()
        for (entity in ownableEntities) {
            for (file in productionFiles()) {
                val text = file.readText()
                for ((body, line) in constructionSites(text, entity)) {
                    if (body.contains("accountId") && !Regex("""\baccountId\s*=\s*null\b""").containsMatchIn(body)) continue
                    val reason = allowListReason(file, entity, line)
                    if (reason != null) continue
                    failures += "${file.name}:$line constructs $entity without accountId"
                }
            }
        }
        assertTrue(
            "unowned constructions found (a birth point is missing its stamp):\n" +
                failures.joinToString("\n"),
            failures.isEmpty()
        )
    }

    @Test
    fun `interval birth point EnergyBucket toEntity stamps the account`() {
        // The single largest table in the database must be born owned:
        // EnergyBucket.toEntity is the interval birth point, and the review
        // failure scenario is exactly this — a trip recorded under A leaving
        // unowned minute rows after the transfer.
        val bucket = EnergyBucket(
            startUtcMillis = 1000L,
            tractionWh = 10.0,
            regeneratedWh = 2.0,
            auxiliaryWh = 1.0,
            integratedSeconds = 60.0,
            speedDistanceKm = 0.5
        )
        val entity = bucket.toEntity("sess-1", 1000L, accountId = "acc-test")
        assertEquals("acc-test", entity.accountId)
        assertEquals(null, bucket.toEntity("sess-1", 1000L).accountId)

        val source = mainFile("telemetry", "EnergyBucketAccumulator.kt").readText()
        val toEntity = source.substringAfter("fun EnergyBucket.toEntity")
            .substringBefore("fun IntervalEntity.toEnergyBucket")
        assertTrue(
            "EnergyBucket.toEntity must carry accountId = accountId onto IntervalEntity",
            Regex("""IntervalEntity\s*\([^)]*accountId\s*=\s*accountId""", RegexOption.DOT_MATCHES_ALL)
                .containsMatchIn(toEntity)
        )

        val frameRepo = mainFile("telemetry", "FrameRepository.kt").readText()
        assertTrue(
            "FrameRepository must pass activeAccountIdProvider() when creating interval rows",
            Regex("""\.toEntity\s*\([^)]*activeAccountIdProvider\(\)""", RegexOption.DOT_MATCHES_ALL)
                .containsMatchIn(frameRepo)
        )
    }

    @Test
    fun `preference proposal merge stamps the account`() {
        val source = mainFile("telemetry", "PreferenceRepository.kt").readText()
        // Bounded on both sides: an unbounded substringAfter runs to end of
        // file and would also match propose(), which was stamped before this
        // fix — the test would then pass with the merge stamp deleted.
        val merge = source.substringAfter("fun mergeIncomingProposal")
            .substringBefore("fun propose(")
        assertTrue(
            "a surfaced proposal must be born owned by the pairing that surfaced it",
            merge.contains("accountId = accountIdProvider()")
        )
    }

    @Test
    fun `the session cost write path stamps the account`() {
        val sessionRepo = mainFile("telemetry", "SessionRepository.kt").readText()
        val costWiring = sessionRepo
            .substringAfter("private val costRepository = SessionCostRepository(")
            .substringBefore("private val readExecutor")
        assertTrue(
            "the cost repository the session writes through must pass SessionRepository's accountIdProvider",
            Regex("""accountIdProvider\s*=\s*accountIdProvider\b""").containsMatchIn(costWiring)
        )
        assertFalse(
            "cost repository must not be wired to a null or dummy provider",
            costWiring.contains("accountIdProvider = { null }") || costWiring.contains("accountIdProvider = null")
        )
    }
    @Test
    fun `event repository is wired to the account provider in production`() {
        // The structural scan above only proves a construction mentions the
        // account; it cannot see a provider that is never wired (the default
        // is `{ null }`, so every event row would be born unowned). This test
        // pins the production wiring itself: TelemetryGraph must feed
        // EventRepository the same pairing-derived provider as line 208.
        val graph = mainFile("telemetry", "TelemetryGraph.kt").readText()
        val construction = graph.substringAfter("EventRepository(")
            .substringBefore("val sessionChanges")
        assertTrue(
            "TelemetryGraph must wire EventRepository to AccountIdProvider.of(...)",
            construction.contains("AccountIdProvider.of(")
        )
    }

    @Test
    fun `minute tick still writes the raw route`() {
        // flushTrack rides the same tick that writes the minute buckets, so a
        // kill mid-drive costs the route only the minute in progress. A prior
        // stamping fix dropped the call; this pins it back.
        val source = mainFile("telemetry", "FrameRepository.kt").readText()
        val tick = source.substringAfter("private fun flushEnergyBuckets(")
            .substringBefore("fun liveEnergySeries()")
        assertTrue(
            "flushEnergyBuckets must call flushTrack(now) before the early return",
            tick.contains("flushTrack(now)")
        )
    }

    @Test
    fun `cost merge stamps phone-origin rows too`() {
        // A phone-origin cost row stamped null would stay unowned forever:
        // nothing on the car re-stamps a landed row and the claim backfill
        // does not cover session_costs. Both constructors must stamp
        // unconditionally; deleting either stamp must fail this test.
        val source = mainFile("telemetry", "SessionCostRepository.kt").readText()
        val merge = source.substringAfter("fun mergeIncoming(")
            .substringBefore("private fun upsert(")
        assertTrue(
            "cost mergeIncoming must stamp the account unconditionally",
            merge.contains("accountId = accountIdProvider()")
        )
        assertFalse(
            "cost mergeIncoming must not leave any origin unstamped",
            merge.contains("else null")
        )
        val upsert = source.substringAfter("private fun upsert(")
            .substringBefore("fun bySession(")
        assertTrue(
            "cost upsert must stamp the account unconditionally",
            upsert.contains("accountId = accountIdProvider()")
        )
        assertFalse(
            "cost upsert must not leave any origin unstamped",
            upsert.contains("else null")
        )
    }

    // --- helpers -------------------------------------------------------------

    private fun constructionSites(text: String, entity: String): List<Pair<String, Int>> {
        val sites = mutableListOf<Pair<String, Int>>()
        var idx = 0
        while (true) {
            idx = text.indexOf("$entity(", idx)
            if (idx < 0) break
            // Word-boundary: BatteryCycleSessionEntity must not match a scan
            // for SessionEntity.
            val before = text.substring(0, idx)
            val prev = if (before.isEmpty()) ' ' else before.last()
            val after = text.substring(idx + entity.length)
            val next = if (after.isEmpty()) ' ' else after.first()
            if (prev.isLetterOrDigit() || next.isLetterOrDigit()) {
                idx = idx + entity.length
                continue
            }
            val line = text.substring(0, idx).count { it == '\n' } + 1
            val start = text.indexOf('(', idx)
            val end = findClosingParen(text, start)
            val body = text.substring(start + 1, if (end > 0) end else text.length)
            sites += body to line
            idx = idx + entity.length
        }
        return sites
    }

    private fun findClosingParen(text: String, open: Int): Int {
        var depth = 0
        for (i in open until text.length) {
            when (text[i]) {
                '(' -> depth++
                ')' -> {
                    depth--
                    if (depth == 0) return i
                }
            }
        }
        return -1
    }

    private fun allowListReason(file: File, entity: String, line: Int): String? {
        val name = file.name
        return when {
            // The migration DDL and the preserved-places restore carry the
            // row's own stored stamp; the DDL lands rows null on purpose.
            name == "TelemetryDatabase.kt" -> "migration / preserve-restore"
            // The entity declaration head of the data class is not a birth.
            name.endsWith("Entity.kt") && line < 40 -> "entity declaration"
            // The reconcile was allowed only when it copies (accountId travels).
            name == "IntervalReconciler.kt" && entity == "IntervalEntity" ->
                "reconcile keeps the stored stamp"
            else -> null
        }
    }

    private fun productionFiles(): List<File> {
        val home = File(
            "src/main/kotlin/com/timhss/capyenergy/telemetry"
        )
        val worktree = File(
            "android/app/src/main/kotlin/com/timhss/capyenergy/telemetry"
        )
        val root = listOf(home, worktree).firstOrNull { it.isDirectory } ?: return emptyList()
        return root.walkTopDown().filter { it.extension == "kt" && it.isFile }.toList()
    }


    private fun mainFile(vararg parts: String): File {
        val home = File("src/main/kotlin/com/timhss/capyenergy" + "/" + parts.joinToString("/"))
        val worktree = File("android/app/src/main/kotlin/com/timhss/capyenergy" + "/" + parts.joinToString("/"))
        val candidates: List<File> = listOf(home, worktree)
        return candidates.firstOrNull { it.isFile }
            ?: error("cannot resolve ${parts.joinToString("/")}")
    }

}