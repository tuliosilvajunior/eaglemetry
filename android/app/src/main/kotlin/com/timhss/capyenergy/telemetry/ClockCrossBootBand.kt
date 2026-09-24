package com.timhss.capyenergy.telemetry

/**
 * Time authority T8, the cross-boot corner: the boot whose wall clock never
 * learned the truth and sits BETWEEN two abreast placed neighbours.
 *
 * Inside one boot the correction is exact arithmetic (the unlock engine,
 * T5). A boot that never saw a truth source has no equation. But when the
 * boot is BRACKETED by placed sessions — sessions whose stamps the sweeper
 * trusts — the neighbours bound where it can fall: its wall window is
 * `[left neighbour end, right neighbour start]`, and the session's own
 * elapsed length (exact on the monotonic axis) caps the window's late edge:
 * the session must still FIT between the stamps. Odometer and SOC deltas
 * only ever rule candidate windows OUT, never in — a counter that cannot
 * prove anything narrows nothing (plan rule 3, hard limits stay hard).
 *
 * The answer is a Band or a refusal, never a point. A point is lawful only
 * when the two neighbours EXACTLY pin the boot: the band degenerates to a
 * single instant the neighbours' arithmetic fixes. Everything else — a band
 * that is merely narrow — stays a band, because a narrower answer is a
 * confidence the data has not bought (plan section 2.2, section 7-8).
 */
object ClockCrossBootBand {

    /** The wall band the placed sessions bound: placement with a span. */
    const val STATE_PLACED_BAND = "placed_band"

    /** No neighbour evidence places the boot; the band stays uncorrectable. */
    const val STATE_UNCORRECTABLE = "uncorrectable"

    /**
     * Two (or more) placed neighbours contradict: the band is empty. The
     * conflict is the answer (never "pick a side"); callers surface it.
     */
    const val STATE_CONFLICT = "conflict"

    const val STATE_EXACT_POINT = "exact_point"

    /** One placed neighbour: a session whose stamps the sweeper trusts. */
    data class PlacedSpan(
        val sessionId: String,
        /** `startedAtUtcMillis` — trusted because the session's boot knew the truth. */
        val startUtcMillis: Long,
        /** COALESCE(endedAtUtcMillis, updatedAtUtcMillis). */
        val endUtcMillis: Long,
        val startOdometerKm: Double? = null,
        val endOdometerKm: Double? = null,
        val startSocPercent: Float? = null,
        val endSocPercent: Float? = null,
    )

    /** The unplaced span: the session whose own boot never learned truth. */
    data class UnplacedSession(
        val sessionId: String,
        /** The session's own boot count (the axis the elapsed reading belongs to). */
        val bootCount: Long? = null,
        /** Exact monotonic length of the session: `endedAtElapsedNanos - startedAtElapsedNanos`. */
        val elapsedDurationMillis: Long,
        val startOdometerKm: Double? = null,
        val endOdometerKm: Double? = null,
        val startSocPercent: Float? = null,
        val endSocPercent: Float? = null,
    )

    /**
     * The interval answer: placement is a span of wall time, not a stamp.
     */
    data class Band(
        val state: String,
        /** Inclusive lower wall bound for the session's START. */
        val bandStartUtcMillis: Long,
        /** Exclusive upper wall bound for the session's START. */
        val bandEndUtcMillis: Long,
        val startNeighbourId: String? = null,
        val endNeighbourId: String? = null,
    )

    /**
     * Places the unplaced span against the ordered placed neighbours.
     *
     * Returns the band for the session's START stamp, computed from
     * (a) the open gap between the two neighbours bracketing it, narrowed
     * by the session's own monotonic duration (the end must also fit), and
     * (b) the odometer/SOC bounds, which only ever reject a candidate gap —
     * they never manufacture one.
     *
     * Never returns a point except the exact-pin case: an empty neighbour
     * gap narrower than one minute bucket whose edges the session fits
     * inside exactly. Narrower-by-arithmetic is still a band.
     */
    fun place(
        unplaced: UnplacedSession,
        placed: List<PlacedSpan>
    ): Band {
        // --- Structural guards: no data or invalid duration, no guess. -------
        if (placed.isEmpty() || unplaced.elapsedDurationMillis < 0L) {
            return Band(
                state = STATE_UNCORRECTABLE,
                bandStartUtcMillis = 0L,
                bandEndUtcMillis = 0L
            )
        }

        // --- Filter out corrupt placed neighbours (end <= start).
        // The real database has 4 PARKED sessions closed with -455 day durations
        // (end before start). Corrupt rows must never act as bracketing bounds.
        val validPlaced = placed.filter { it.endUtcMillis > it.startUtcMillis }
        if (validPlaced.isEmpty()) {
            return Band(
                state = STATE_UNCORRECTABLE,
                bandStartUtcMillis = 0L,
                bandEndUtcMillis = 0L
            )
        }

        // --- Sort the neighbours and merge overlapping intervals to find genuine gaps.
        // Real data carries 2025 and 2027 stamps mixed, and concurrent sessions (e.g.
        // CONTINUOUS overlapping with TRIP). Any time a session is active is occupied;
        // genuine gaps only exist between the end of an occupied span and the start of the next.
        val sorted = validPlaced.sortedBy { it.startUtcMillis }
        val windows: MutableList<Pair<PlacedSpan, PlacedSpan>> = mutableListOf()
        var currentSpanLeft = sorted[0]
        var currentSpanEnd = sorted[0].endUtcMillis

        for (i in 1 until sorted.size) {
            val next = sorted[i]
            if (next.startUtcMillis < currentSpanEnd) {
                if (next.endUtcMillis > currentSpanEnd) {
                    currentSpanEnd = next.endUtcMillis
                    currentSpanLeft = next
                }
            } else {
                windows.add(Pair(currentSpanLeft, next))
                currentSpanLeft = next
                currentSpanEnd = next.endUtcMillis
            }
        }

        var candidates: MutableList<Band> = mutableListOf()
        for ((left, right) in windows) {
            val lowerBound = left.endUtcMillis
            val upperBound = right.startUtcMillis - unplaced.elapsedDurationMillis
            if (upperBound < lowerBound) continue // the session cannot fit: this gap is not a home
            val band = Band(
                state = STATE_PLACED_BAND,
                bandStartUtcMillis = lowerBound,
                bandEndUtcMillis = upperBound,
                startNeighbourId = left.sessionId,
                endNeighbourId = right.sessionId
            )
            val odoNarrowed = narrowByOdometer(band, unplaced, left, right) ?: continue
            candidates.add(narrowBySoc(odoNarrowed, unplaced, left, right))
        }

        // --- Resolve candidates: exactly one band or conflict. -----------------
        if (candidates.isEmpty()) {
            // Single-side bracket still says something: after the last placed
            // session the span could start anywhere, so the answer is honest
            // ignorance — the state is uncorrectable.
            return Band(
                state = STATE_UNCORRECTABLE,
                bandStartUtcMillis = 0L,
                bandEndUtcMillis = 0L
            )
        }

        // One candidate: the band stands on the session window alone. The
        // only lawful point is the EXACT-pin case — the neighbours agree on
        // the instant and the arithmetic cannot move (lower == upper). A band
        // that is merely narrow stays a band: closer-by-coincidence is still
        // a guess, not an equation (plan section 7-8).
        if (candidates.size == 1) {
            val band = candidates[0]
            if (band.bandEndUtcMillis == band.bandStartUtcMillis) {
                return band.copy(state = STATE_EXACT_POINT)
            }
            return band
        }

        // More than one open gap could host the session: the neighbours
        // contradict and picking one would be a silent guess. Surface it.
        return Band(
            state = STATE_CONFLICT,
            bandStartUtcMillis = 0L,
            bandEndUtcMillis = 0L,
            startNeighbourId = candidates.first().startNeighbourId,
            endNeighbourId = candidates.last().endNeighbourId
        )
    }

    /**
     * Odometer is a forward-only counter read against the wall stamps of the
     * placed neighbours (plan section 6: it bounds, never places). Its only
     * lawful work here is REJECTING a window whose meter bookkeeping cannot
     * be true: the unplaced session's odometer must sit between the
     * neighbours' readings, within the plausibility cap the accumulator
     * already enforces per step. A missing or impossible odometer never
     * rejects anything — a bad counter narrows nothing, the window keeps the
     * session-window bounds (plan rule 3: hard limits stay hard).
     *
     * SOC is bounded 0..100 with no monotonic guarantee over the driving
     * day (charge raises it, drive lowers it), so it cannot narrow the wall
     * window on its own; the valid-range check below only guards against an
     * inverted sensor being used as a signal at all.
     */
    private fun narrowByOdometer(
        band: Band,
        unplaced: UnplacedSession,
        left: PlacedSpan,
        right: PlacedSpan
    ): Band? {
        val selfStartOdo = unplaced.startOdometerKm
        val selfEndOdo = unplaced.endOdometerKm
        if (selfStartOdo == null && selfEndOdo == null) return band

        if (selfStartOdo != null && selfEndOdo != null) {
            val selfDelta = selfEndOdo - selfStartOdo
            if (selfDelta < 0.0 || selfDelta > MAX_PLAUSIBLE_ODOMETER_DELTA_KM) {
                // Impossible self delta: corrupted meter, window alone governs per rule.
                return band
            }
        }

        val leftOdo = left.endOdometerKm ?: left.startOdometerKm
        val rightOdo = right.startOdometerKm ?: right.endOdometerKm
        if (leftOdo == null && rightOdo == null) return band

        val wallGapMillis = right.startUtcMillis - left.endUtcMillis
        if (wallGapMillis <= 0L) return band
        val wallGapMinutes = wallGapMillis / 60_000.0
        val budgetKm = wallGapMinutes / 60.0 * MAX_PLAUSIBLE_SPEED_KMH

        // If both neighbours carry odometer readings:
        if (leftOdo != null && rightOdo != null) {
            if (leftOdo > rightOdo) {
                // Inverted neighbour odometer: unusable neighbour evidence, window alone governs.
                return band
            }
            if (rightOdo - leftOdo > budgetKm) {
                // Gap is too short in time for the distance between neighbours at speed cap.
                return null
            }
        }

        // Forward-counter constraints: meter never runs backwards
        val earliestSelfOdo = selfStartOdo ?: selfEndOdo!!
        if (leftOdo != null) {
            if (earliestSelfOdo < leftOdo) return null
            if (earliestSelfOdo - leftOdo > budgetKm) return null
        }

        val latestSelfOdo = selfEndOdo ?: selfStartOdo!!
        if (rightOdo != null) {
            if (latestSelfOdo > rightOdo) return null
            if (rightOdo - latestSelfOdo > budgetKm) return null
        }

        if (selfStartOdo != null && selfEndOdo != null) {
            val delta = selfEndOdo - selfStartOdo
            if (delta > budgetKm) return null
        }

        return band
    }

    private fun selfOdoDelta(unplaced: UnplacedSession): Double? =
        if (unplaced.startOdometerKm != null && unplaced.endOdometerKm != null) {
            val delta = unplaced.endOdometerKm - unplaced.startOdometerKm
            if (delta in 0.0..MAX_PLAUSIBLE_ODOMETER_DELTA_KM) delta else null
        } else {
            null
        }

    /**
     * SOC is a bounded 0..100 counter with no monotonic guarantee over the
     * driving day (charge raises it, drive lowers it), so - per plan rule
     * 3 - it cannot narrow the wall window on its own; the validity check
     * only guards a future arm against an inverted sensor being read as
     * truth.
     */
    private fun narrowBySoc(
        band: Band,
        unplaced: UnplacedSession,
        left: PlacedSpan,
        right: PlacedSpan
    ): Band {
        val values = listOf(
            unplaced.startSocPercent, unplaced.endSocPercent,
            left.startSocPercent, left.endSocPercent,
            right.startSocPercent, right.endSocPercent
        )
        // A SOC value outside 0..100 is an inversion, not a clock signal.
        // SOC cannot reject a window by itself; the validity check exists so
        // a future arm never reads an inverted sensor as truth. The band the
        // session window produced stands unchanged either way.
        values.all { it == null || it in 0.0f..100.0f }
        return band
    }

    /** The accumulator's speed ceiling: the fastest run the bus ever saw. */
    private const val MAX_PLAUSIBLE_SPEED_KMH = 220.0

    /**
     * The absolute odometer delta ceiling: beyond it the meter is not
     * evidence, the session window governs alone.
     */
    private const val MAX_PLAUSIBLE_ODOMETER_DELTA_KM = 24_000.0

}
