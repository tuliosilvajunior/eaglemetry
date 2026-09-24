package com.timhss.capyenergy.telemetry

import java.io.File
import java.sql.DriverManager
import org.junit.Assume
import org.junit.Test

/**
 * T3 real-car validation: feeds [OffsetDetector] with rows from the live
 * pull (`telemetry_snapshot_2026-09-12b.db`, 2026-09-12 via adb) instead of
 * the built fixtures in [OffsetDetectorTest].
 *
 * The honest input set: `telemetry_events` rows whose boot is certain — the
 * event's `sessionId` names a same-boot session whose
 * `[startedAtElapsedNanos, endedAtElapsedNanos]` contains the event's
 * `occurredAtElapsedNanos`. Rows failing that bar are excluded, never
 * guessed: a guessed boot is a fake pair, and a fake pair proves nothing.
 * Feed shape per row: `(session.startedAtBootCount, occurredAtUtcMillis,
 * occurredAtElapsedNanos)`.
 *
 * Known coverage (snapshot b, counted 2026-09-12): 3,433 healthy (2026) +
 * 21 bad (2025-05 factory-default band) certain rows across 14 boots. The
 * 2027-12 forward cluster has no paired rows in this pull — interval rows
 * carry no monotonic pair and event rows carry no boot — so half 1 below
 * covers the 2025-05 band only, stated explicitly.
 *
 * Run: `CAPY_SNAPSHOT_DB=/path/to/telemetry_snapshot_2026-09-12b.db
 * ./gradlew :app:testDebugUnitTest --tests
 * "com.timhss.capyenergy.telemetry.OffsetDetectorRealDataTest"`.
 * Without the env var (or `-Dcapy.snapshot.db=...`) the suite skips via
 * Assume: the 11 MB pull is evidence, not repo content, and CI has no car.
 */
class OffsetDetectorRealDataTest {

    private data class Row(val boot: Long, val wall: Long, val elapsed: Long)

    private fun snapshotFile(): File {
        val path = System.getenv("CAPY_SNAPSHOT_DB")
            ?: System.getProperty("capy.snapshot.db")
            ?: ""
        Assume.assumeTrue(
            "Set CAPY_SNAPSHOT_DB=/path/to/telemetry_snapshot_*.db to run the real-car validation",
            path.isNotBlank() && File(path).isFile,
        )
        return File(path)
    }

    private fun loadCertainRows(db: File): List<Row> {
        val rows = mutableListOf<Row>()
        val conn = DriverManager.getConnection("jdbc:sqlite:${db.absolutePath}")
        conn.use { c ->
            // read-only: the pull is evidence, never mutated.
            c.createStatement().use { it.execute("PRAGMA query_only = ON") }
            c.prepareStatement(
                "SELECT s.startedAtBootCount, e.occurredAtUtcMillis, e.occurredAtElapsedNanos " +
                    "FROM telemetry_events e JOIN session s ON s.id = e.sessionId " +
                    "WHERE s.startedAtBootCount = s.endedAtBootCount " +
                    "AND e.occurredAtElapsedNanos BETWEEN " +
                    "s.startedAtElapsedNanos AND s.endedAtElapsedNanos"
            ).use { q ->
                val rs = q.executeQuery()
                while (rs.next()) {
                    rows += Row(rs.getLong(1), rs.getLong(2), rs.getLong(3))
                }
            }
        }
        return rows
    }

    @Test
    fun `real pull - bad factory-default rows rejected, healthy rows kept`() {
        val rows = loadCertainRows(snapshotFile())
        Assume.assumeTrue("snapshot has no certain rows", rows.isNotEmpty())

        val samples = rows.map {
            OffsetDetector.ClockSample(
                bootCount = it.boot,
                wallMillis = it.wall,
                elapsedNanos = it.elapsed,
            )
        }
        // Ground truth independent of the detector: a row is bad when its
        // wall stamp sits in the factory-default band (May 2025 — the car
        // assumes it when it does not know the time); everything else in
        // this pull is 2026 healthy mass. Year-month arithmetic, no
        // detector constant.
        val badWalls = rows.filter {
            java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply {
                timeInMillis = it.wall
            }.let { cal ->
                cal.get(java.util.Calendar.YEAR) == 2025
            }
        }.map { it.wall }.toSet()

        val result = OffsetDetector.detect(samples)
        val rejectedWalls = result.boots.values
            .flatMap { it.rejected }
            .map { it.wallMillis }
            .toSet()

        // Half 1: every bad row the pull can pair is flagged...
        val missed = badWalls - rejectedWalls
        // ...and half 2 (the one that matters more): no healthy row is.
        val falseHits = rejectedWalls - badWalls

        // Counts ride along in the message so a failure prints its own census.
        org.junit.Assert.assertTrue(
            "missed ${missed.size} of ${badWalls.size} bad rows (e.g. ${missed.take(5)})",
            missed.isEmpty(),
        )
        org.junit.Assert.assertTrue(
            "rejected ${falseHits.size} healthy rows " +
                "(e.g. ${falseHits.take(5)} of ${rows.size - badWalls.size} healthy)",
            falseHits.isEmpty(),
        )
    }
}
