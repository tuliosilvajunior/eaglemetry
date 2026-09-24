package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Time authority T8, the cross-boot corner.
 *
 * The captain's rule is the test charter: a boot whose wall clock never
 * learned the truth receives an honest INTERVAL when two placed neighbours
 * bracket, never a fabricated point. The three families that killed prior
 * reviews are each pinned below:
 *
 * 1. band-not-point — a band between close neighbours is a band, and only
 *    the neighbours' exact-pin conjunction is a point;
 * 2. out-of-order neighbours — the real data carries 2025 and 2027 stamps
 *    shuffled, so the input order is never trusted, and no invert/negative
 *    band ever escapes;
 * 3. idempotency — running the place over the SAME state again must not
 *    narrow the band by mistake (the band is a verdict, not a kernel).
 *
 * Every stamp is composed as `offset + elapsed`, exempt from the
 * no-constants rule; no wall date appears in an assertion, only offsets
 * and deltas.
 *
 * Mutation contract: delete the `upperBound < lowerBound` fit gate or the
 * sort, and at least one test here must FAIL. A test that still passes
 * with the rule deleted tests its own harness, not the rule.
 */
class ClockCrossBootBandTest {

    /** The boot default offset, composed like the sweeper: offset + elapsed. */
    private val defaultOffset = 1_748_048_880_000L

    /** A healthy boot's offset, one hour after the default. */
    private val healthy = defaultOffset + 3_600_000L

    private fun placed(
        id: String,
        startUtcMillis: Long,
        durationMillis: Long = 60_000L,
        startOdo: Double? = null,
        endOdo: Double? = null,
        startSoc: Float? = null,
        endSoc: Float? = null
    ) = ClockCrossBootBand.PlacedSpan(
        sessionId = id,
        startUtcMillis = startUtcMillis,
        endUtcMillis = startUtcMillis + durationMillis,
        startOdometerKm = startOdo,
        endOdometerKm = endOdo,
        startSocPercent = startSoc,
        endSocPercent = endSoc
    )

    private fun unplaced(
        id: String = "unplaced",
        durationMillis: Long = 10 * 60_000L,
        startOdo: Double? = null,
        endOdo: Double? = null,
        startSoc: Float? = null,
        endSoc: Float? = null
    ) = ClockCrossBootBand.UnplacedSession(
        sessionId = id,
        bootCount = 7L,
        elapsedDurationMillis = durationMillis,
        startOdometerKm = startOdo,
        endOdometerKm = endOdo,
        startSocPercent = startSoc,
        endSocPercent = endSoc
    )

    // ---------------------------------------------------------------------
    // 1. Band not point.
    // ---------------------------------------------------------------------
    @Test
    fun `a bracketed boot gets a band, not a point`() {
        val left = placed("left", healthy, 10 * 60_000L)
        val right = placed("right", healthy + 60 * 60_000L, 10 * 60_000L)
        val band = ClockCrossBootBand.place(unplaced(), listOf(left, right))
        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        // The band bounds the START between left's end and the LATE cap
        // right.start - duration (the session's own length must still fit).
        // right.start - duration = healthy + 50 min here.
        assertEquals(left.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(right.startUtcMillis - 10 * 60_000L, band.bandEndUtcMillis)
        // A point would be bandEnd == bandStart — never here.
        assertTrue(band.bandEndUtcMillis > band.bandStartUtcMillis)
    }

    /**
     * Two CLOSE neighbours produce a NARROW band: still a band. Only the
     * neighbours' exact degenerate conjunction (their stamps touching) may
     * return a point, and that point is the neighbours' information, not
     * the session's guess.
     */
    @Test
    fun `close neighbours narrow the band but never to a point`() {
        val left = placed("left", healthy, 60 * 60_000L)
        val right = placed("right", healthy + 90 * 60_000L, 60_000L)
        val duration = 25 * 60_000L
        val band = ClockCrossBootBand.place(unplaced(durationMillis = duration), listOf(left, right))

        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        // 65 min of open gap; the session's own 25 min keeps the start
        // pinned before right.start - duration.
        assertEquals(left.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(right.startUtcMillis - duration, band.bandEndUtcMillis)
        assertTrue(band.bandEndUtcMillis > band.bandStartUtcMillis)
    }

    /**
     * The degenerate conjunction: the neighbours' stamps touch exactly and
     * the unplaced session has zero duration. Then the band is one instant:
     * the only point a band may become. upper = right.start - 0 =
     * right.start; lower = left.end; the touching stamps make upper ==
     * lower exactly, so the one instant is the neighbours' arithmetic, not
     * a guess.
     */
    @Test
    fun `neighbours that touch exactly and fit yield the lawful point`() {
        val left = placed("left", healthy, 60_000L)
        val right = placed("right", healthy + 60_000L, 60_000L)
        val band = ClockCrossBootBand.place(unplaced(durationMillis = 0L), listOf(left, right))

        assertEquals(ClockCrossBootBand.STATE_EXACT_POINT, band.state)
        assertEquals(left.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(right.startUtcMillis, band.bandEndUtcMillis)
        assertEquals(band.bandStartUtcMillis, band.bandEndUtcMillis)
    }
    // ---------------------------------------------------------------------
    // 2. Out-of-order neighbours (the real data's case).
    // ---------------------------------------------------------------------
    @Test
    fun `neighbours delivered out of order produce a straight band, never inverted`() {
        val rightStampsLater = placed("late", healthy + 60 * 60_000L, 10 * 60_000L)
        val rightStampsEarlier = placed("early", healthy, 10 * 60_000L)
        // Deliver exactly the order the SQL returned: later first.
        val band = ClockCrossBootBand.place(
            unplaced(),
            listOf(rightStampsLater, rightStampsEarlier)
        )

        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        assertTrue(
            "band must never be inverted",
            band.bandEndUtcMillis > band.bandStartUtcMillis
        )
        assertEquals(rightStampsEarlier.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(rightStampsLater.startUtcMillis - 10 * 60_000L, band.bandEndUtcMillis)
    }

    /**
     * A session LONGER than the gap between its neighbours cannot fit: no
     * band is carved from a gap that cannot host it, and nothing (least of
     * all a negative interval) escapes.
     */
    @Test
    fun `a session longer than the gap is uncorrectable, never a negative band`() {
        val left = placed("left", healthy, 60_000L)
        val right = placed("right", healthy + 5 * 60_000L, 60_000L)
        val band = ClockCrossBootBand.place(
            unplaced(durationMillis = 30 * 60_000L),
            listOf(left, right)
        )

        assertEquals(ClockCrossBootBand.STATE_UNCORRECTABLE, band.state)
        assertTrue(band.bandEndUtcMillis >= band.bandStartUtcMillis)
    }

    // ---------------------------------------------------------------------
    // 3. Idempotency: the same state, the same answer.
    // ---------------------------------------------------------------------
    @Test
    fun `running again over the same state returns the same band, never narrower`() {
        val left = placed("left", healthy, 60 * 60_000L, startOdo = 120.0, endOdo = 160.0)
        val right = placed("right", healthy + 90 * 60_000L, 60_000L, startOdo = 200.0, endOdo = 205.0)
        val un = unplaced(durationMillis = 20 * 60_000L, startOdo = 170.0, endOdo = 175.0)
        val first = ClockCrossBootBand.place(un, listOf(left, right))
        val second = ClockCrossBootBand.place(un, listOf(left, right))

        assertEquals(first, second)
        // Idempotency means width stability: a re-run can never quietly
        // decide "less is known now".
        assertEquals(first.bandEndUtcMillis - first.bandStartUtcMillis,
            second.bandEndUtcMillis - second.bandStartUtcMillis)
    }

    // ---------------------------------------------------------------------
    // 4. Conflict (plan section 7-3): more than one gap could host it.
    // ---------------------------------------------------------------------
    @Test
    fun `two disjoint gaps both able to host the session surface a conflict`() {
        val a = placed("a", healthy, 10 * 60_000L)
        val b = placed("b", healthy + 90 * 60_000L, 10 * 60_000L)
        val c = placed("c", healthy + 240 * 60_000L, 10 * 60_000L)
        val band = ClockCrossBootBand.place(
            unplaced(durationMillis = 5 * 60_000L),
            listOf(a, b, c)
        )

        assertEquals(ClockCrossBootBand.STATE_CONFLICT, band.state)
        // No bounds leak out of a conflict: the caller surfaces it, the rows
        // stay as they were.
        assertTrue(band.bandEndUtcMillis == 0L && band.bandStartUtcMillis == 0L)
    }

    // ---------------------------------------------------------------------
    // Hard limits stay hard: a missing or unusable odometer cannot widen
    // anything, and a valid odometer can only REJECT a window.
    // ---------------------------------------------------------------------
    @Test
    fun `a session whose odometer cannot belong between its neighbours is rejected`() {
        // Neighbours span odometer 120.0 -> 130.0; the unplaced session
        // claims odometer 9_000: the meter cannot have moved that far in
        // this gap, so the gap cannot host it.
        val left = placed("left", healthy, 60_000L, startOdo = 120.0, endOdo = 125.0)
        val right = placed("right", healthy + 30 * 60_000L, 60_000L, startOdo = 128.0, endOdo = 130.0)
        val band = ClockCrossBootBand.place(
            unplaced(durationMillis = 10 * 60_000L, startOdo = 9_000.0, endOdo = 9_001.0),
            listOf(left, right)
        )

        assertEquals(ClockCrossBootBand.STATE_UNCORRECTABLE, band.state)
    }

    /**
     * An unusable odometer reading (a backwards jump, a phantom delta) never
     * widens or narrows the verdict: the session window alone governs.
     */
    @Test
    fun `an impossible odometer reading is dropped, the window still governs`() {
        val left = placed("left", healthy, 60_000L, startOdo = 120.0, endOdo = 125.0)
        val right = placed("right", healthy + 30 * 60_000L, 60_000L, startOdo = 128.0, endOdo = 130.0)
        // Self delta negative: unusable evidence.
        val band = ClockCrossBootBand.place(
            unplaced(durationMillis = 10 * 60_000L, startOdo = 200.0, endOdo = 100.0),
            listOf(left, right)
        )

        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        assertEquals(left.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(right.startUtcMillis - 10 * 60_000L, band.bandEndUtcMillis)
    }

    /**
     * No placed neighbours at all: the honest answer is refusal (negative
     * evidence is not placement).
     */
    @Test
    fun `no neighbours means uncorrectable, never a fabricated band`() {
        val band = ClockCrossBootBand.place(unplaced(), emptyList())
        assertEquals(ClockCrossBootBand.STATE_UNCORRECTABLE, band.state)
        assertEquals(0L, band.bandStartUtcMillis)
        assertEquals(0L, band.bandEndUtcMillis)
    }

    /**
     * Mutation proof (the review family that matters): the fit gate
     * `upperBound < lowerBound` is load-bearing. Removing it would let a
     * too-long session claim a gap it cannot fit and produce a negative
     * band. The inverse-order test exercises it directly — an input ordered
     * so a naive first-two-pick would bracket wrongly still lands correct.
     */
    @Test
    fun `the fit gate holds a too-long session out of a small gap and keeps the fit`() {
        val bigLeft = placed("bigLeft", healthy, 60 * 60_000L)
        val bigRight = placed("bigRight", healthy + 240 * 60_000L, 60_000L)
        val smallLeft = placed("smallLeft", healthy + 269 * 60_000L, 60_000L)
        val smallRight = placed("smallRight", healthy + 270 * 60_000L, 60_000L)
        val un = unplaced(durationMillis = 30 * 60_000L)
        // The 240-minute gap hosts the 30-minute session; the 28-minute gap
        // between bigRight and smallLeft cannot host it — that is the fit
        // gate at work, so only one band remains and no conflict is raised.
        val band = ClockCrossBootBand.place(
            un,
            listOf(smallRight, bigRight, smallLeft, bigLeft) // shuffled on purpose
        )

        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        assertEquals(bigLeft.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(bigRight.startUtcMillis - 30 * 60_000L, band.bandEndUtcMillis)
        assertNotEquals(smallLeft.endUtcMillis, band.bandStartUtcMillis)
    }

    /**
     * Extreme close neighbours: gap is 10_001 ms, session is 10_000 ms.
     * The resulting band has width 1 ms. Even a 1 ms band MUST stay a
     * band, never rounded to a point.
     */
    @Test
    fun `neighbours with gap of one millisecond still return a band, never a point`() {
        val left = placed("left", healthy, 60_000L)
        val right = placed("right", healthy + 60_000L + 10_001L, 60_000L)
        val band = ClockCrossBootBand.place(unplaced(durationMillis = 10_000L), listOf(left, right))

        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        assertEquals(left.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(left.endUtcMillis + 1L, band.bandEndUtcMillis)
        assertEquals(1L, band.bandEndUtcMillis - band.bandStartUtcMillis)
    }

    /**
     * Non-zero duration session that exactly fits the gap with 0 ms slack:
     * the only mathematical point.
     */
    @Test
    fun `non-zero duration session that exactly fits gap returns exact point`() {
        val left = placed("left", healthy, 60_000L)
        val right = placed("right", healthy + 60_000L + 10_000L, 60_000L)
        val band = ClockCrossBootBand.place(unplaced(durationMillis = 10_000L), listOf(left, right))

        assertEquals(ClockCrossBootBand.STATE_EXACT_POINT, band.state)
        assertEquals(left.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(left.endUtcMillis, band.bandEndUtcMillis)
    }

    /**
     * Forward counter: an unplaced session whose odometer reading is BEFORE
     * the left neighbour's ending odometer is impossible and MUST be rejected,
     * even when the time gap is wide (e.g. 5 hours).
     */
    @Test
    fun `unplaced session with odometer before left neighbour is rejected as forward counter violation`() {
        val left = placed("left", healthy, 60_000L, startOdo = 450.0, endOdo = 500.0)
        val right = placed("right", healthy + 5 * 3600_000L, 60_000L, startOdo = 550.0, endOdo = 600.0)
        // unplaced odometer claims 100.0 km (well before left's 500.0 km).
        val band = ClockCrossBootBand.place(
            unplaced(durationMillis = 10 * 60_000L, startOdo = 100.0, endOdo = 105.0),
            listOf(left, right)
        )

        assertEquals(ClockCrossBootBand.STATE_UNCORRECTABLE, band.state)
    }

    /**
     * Forward counter: an unplaced session whose odometer reading is AFTER
     * the right neighbour's starting odometer is impossible and MUST be rejected.
     */
    @Test
    fun `unplaced session with odometer after right neighbour is rejected as forward counter violation`() {
        val left = placed("left", healthy, 60_000L, startOdo = 450.0, endOdo = 500.0)
        val right = placed("right", healthy + 5 * 3600_000L, 60_000L, startOdo = 550.0, endOdo = 600.0)
        // unplaced odometer claims 700.0 km (past right's 550.0 km).
        val band = ClockCrossBootBand.place(
            unplaced(durationMillis = 10 * 60_000L, startOdo = 700.0, endOdo = 705.0),
            listOf(left, right)
        )

        assertEquals(ClockCrossBootBand.STATE_UNCORRECTABLE, band.state)
    }

    /**
     * Forward counter amidst legacy data: real DB contains 2025 and 2027 sessions.
     * The forward counter rules out the 2025 and 2027 gaps and correctly places
     * the unplaced session in the genuine 2026 gap without false conflict.
     */
    @Test
    fun `forward counter resolves genuine gap amidst 2025 and 2027 legacy neighbours without false conflict`() {
        val legacy2025 = placed("legacy2025", defaultOffset, 60_000L, startOdo = 50.0, endOdo = 55.0)
        val session2026A = placed("session2026A", healthy, 60_000L, startOdo = 5000.0, endOdo = 5010.0)
        val session2026B = placed("session2026B", healthy + 120 * 60_000L, 60_000L, startOdo = 5030.0, endOdo = 5040.0)
        val legacy2027 = placed("legacy2027", healthy + 400 * 86400_000L, 60_000L, startOdo = 9000.0, endOdo = 9010.0)

        val un = unplaced(
            durationMillis = 30 * 60_000L,
            startOdo = 5015.0,
            endOdo = 5025.0
        )
        val band = ClockCrossBootBand.place(
            un,
            listOf(legacy2027, session2026A, legacy2025, session2026B) // shuffled
        )

        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        assertEquals(session2026A.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(session2026B.startUtcMillis - 30 * 60_000L, band.bandEndUtcMillis)
    }

    /**
     * Corrupted neighbour with endUtcMillis < startUtcMillis (the 4 PARKED sessions
     * with -455 day duration in field data) is dropped; the genuine gap between
     * valid placed neighbours is found.
     */
    @Test
    fun `corrupted placed neighbour with end before start is ignored, real gap between valid neighbours is found`() {
        val left = placed("left", healthy, 60 * 60_000L)
        // Corrupt session: ended 455 days before starting.
        val corrupt = ClockCrossBootBand.PlacedSpan(
            sessionId = "corrupt",
            startUtcMillis = healthy + 90 * 60_000L,
            endUtcMillis = healthy + 10 * 60_000L
        )
        val right = placed("right", healthy + 180 * 60_000L, 60 * 60_000L)
        val un = unplaced(durationMillis = 30 * 60_000L)

        val band = ClockCrossBootBand.place(un, listOf(left, corrupt, right))

        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        assertEquals(left.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(right.startUtcMillis - 30 * 60_000L, band.bandEndUtcMillis)
    }

    /**
     * Overlapping placed sessions are merged into occupied spans.
     * An impossible window between overlapping sessions is NEVER formed.
     */
    @Test
    fun `overlapping placed sessions are merged into occupied time, preventing impossible windows inside active sessions`() {
        val sessionA = placed("A", healthy, 120 * 60_000L) // 0..120 min
        val sessionB = placed("B", healthy + 30 * 60_000L, 30 * 60_000L) // 30..60 min
        val sessionC = placed("C", healthy + 75 * 60_000L, 30 * 60_000L) // 75..105 min
        val sessionD = placed("D", healthy + 180 * 60_000L, 60 * 60_000L) // 180..240 min

        val un = unplaced(durationMillis = 10 * 60_000L)
        val band = ClockCrossBootBand.place(un, listOf(sessionA, sessionB, sessionC, sessionD))

        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        // Must be placed between A's end (120 min) and D's start (180 min),
        // NEVER inside A's span (e.g. between B and C).
        assertEquals(sessionA.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(sessionD.startUtcMillis - 10 * 60_000L, band.bandEndUtcMillis)
    }

    /**
     * A negative unplaced session duration is impossible: refused as uncorrectable,
     * never widening the upper bound beyond right.start.
     */
    @Test
    fun `negative unplaced session duration is rejected as uncorrectable, never widens upper bound`() {
        val left = placed("left", healthy, 60_000L)
        val right = placed("right", healthy + 60 * 60_000L, 60_000L)
        val band = ClockCrossBootBand.place(unplaced(durationMillis = -60_000L), listOf(left, right))

        assertEquals(ClockCrossBootBand.STATE_UNCORRECTABLE, band.state)
        assertEquals(0L, band.bandStartUtcMillis)
        assertEquals(0L, band.bandEndUtcMillis)
    }

    /**
     * Neighbours with backwards odometer readings do not cause crash or false rejection;
     * window alone governs.
     */
    @Test
    fun `neighbours with backwards odometer do not falsely narrow or cause crash`() {
        val left = placed("left", healthy, 60_000L, startOdo = 600.0, endOdo = 600.0)
        val right = placed("right", healthy + 30 * 60_000L, 60_000L, startOdo = 500.0, endOdo = 500.0)
        val un = unplaced(durationMillis = 10 * 60_000L, startOdo = 550.0, endOdo = 555.0)

        val band = ClockCrossBootBand.place(un, listOf(left, right))
        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        assertEquals(left.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(right.startUtcMillis - 10 * 60_000L, band.bandEndUtcMillis)
    }

    /**
     * SOC values outside 0..100 are sensor inversions, not signals:
     * they never alter band bounds or cause rejection.
     */
    @Test
    fun `SOC values outside 0 to 100 never alter band bounds`() {
        val left = placed("left", healthy, 60_000L, startSoc = -15f, endSoc = 150f)
        val right = placed("right", healthy + 30 * 60_000L, 60_000L, startSoc = 200f, endSoc = -50f)
        val un = unplaced(durationMillis = 10 * 60_000L, startSoc = 500f, endSoc = -100f)

        val band = ClockCrossBootBand.place(un, listOf(left, right))
        assertEquals(ClockCrossBootBand.STATE_PLACED_BAND, band.state)
        assertEquals(left.endUtcMillis, band.bandStartUtcMillis)
        assertEquals(right.startUtcMillis - 10 * 60_000L, band.bandEndUtcMillis)
    }
}
