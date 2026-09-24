package com.timhss.capyenergy.telemetry

import kotlin.math.abs
import kotlin.math.max

/**
 * Seed detector for untrusted wall-clock stamps. Read-only: it rejects
 * nothing from storage, rewrites no row, learns no anchor. It answers one
 * question — which samples sit off their boot's line — from the distribution,
 * never from any single stored row.
 *
 * Inside one boot `wall - elapsed` is a fixed offset, so honest samples of a
 * boot agree up to the microseconds between the two reads, while a stamp the
 * head unit wrote before `AutoTimeService` synced sits hundreds of days away.
 * With ~1% contamination the per-boot median is immune (it needs >50% of the
 * boot to move) and the MAD scale comes from the healthy majority, which is
 * why this is median+MAD and not mean/std: two points 455 days out move the
 * mean by ~9 days and inflate the std past the very outliers it should catch.
 *
 * Two arms, because the recurring boot default is a dense cluster, not an
 * outlier:
 *
 * - Distributional: `|O - med| > max(k * MAD, 15 min)` per boot, `k = 7`,
 *   MAD normalized x1.4826. Needs [MIN_SAMPLES_PER_BOOT] paired samples;
 *   below that the median is one bad row away from poisoned, so this arm
 *   abstains and the verdict carries [StructuralFlag.BELOW_MINIMUM_SAMPLES].
 *   A boot that abstains with no structural finding is unattested, never
 *   clean: consumers must treat it as unknown.
 * - Structural: a wall stamp recorded under 2+ boot counts (the duplicate
 *   census), and a flat run at the boot's start followed by a giant jump
 *   (the un-synced prefix that warms up when the truth lands). When the two
 *   agree — the prefix runs on stamps the census knows repeat across boots —
 *   the prefix is rejected even when it is the majority and the median sits
 *   inside it. That override is the whole point: a dense default cluster
 *   looks normal to median+MAD alone. On override the median is recomputed
 *   over the post-jump tail, so the verdict's offset never describes the
 *   default mass; when the tail itself is below minimum the median stays
 *   unknown rather than naming the poisoned value.
 *
 * What this deliberately does not do: pick a winner between two boots that
 * share a stamp (that needs a truth source — T4/T5), reject on census
 * evidence alone (two honest boots can re-record one minute across a reboot,
 * so census-only is flag, never reject), or name any date. There is no
 * known-bad constant anywhere here; the bad list is populated by evidence
 * downstream.
 *
 * Segregation is the caller's job: pass only samples whose boot is known.
 * Rows with unknown boot and sessions that span a reboot have no shared
 * monotonic axis and belong to the cross-boot corner, not to this fold.
 *
 * Pure Kotlin, no Android clock: runs on the JVM test rig.
 */
object OffsetDetector {
    /**
     * Below this many paired samples the median can be carried by a single
     * bad row, so the distributional arm abstains and only the structural
     * arms run.
     */
    const val MIN_SAMPLES_PER_BOOT = 8

    /** Rejection strictness: how many normalized MADs off-median is bad. */
    const val MAD_FACTOR = 7.0

    /** Gaussian-consistency normalization for MAD. */
    const val MAD_NORMALIZER = 1.4826

    private const val NANOS_PER_MILLISECOND = 1_000_000L

    /**
     * One stamp on the monotonic axis. [elapsedNanos] is null for legacy rows
     * that lost their pairing: they skip the offset arms and join only the
     * duplicate census, which needs no elapsed reading.
     */
    data class ClockSample(
        val bootCount: Long,
        val wallMillis: Long,
        val elapsedNanos: Long?
    )

    enum class StructuralFlag {
        /** The attestable mass is below [MIN_SAMPLES_PER_BOOT]: MAD abstained. */
        BELOW_MINIMUM_SAMPLES,

        /** At least one of this boot's stamps was recorded under another boot. */
        DUPLICATE_STAMP,

        /** Flat run at the boot's start, then a jump past the threshold. */
        START_PLATEAU
    }

    data class BootVerdict(
        val bootCount: Long,
        /** Robust offset of the accepted mass; null when unattested. */
        val medianOffsetMillis: Long?,
        val madMillis: Long?,
        /** Samples off the boot's line by distribution, or on a proven default prefix. */
        val rejected: List<ClockSample>,
        val flags: Set<StructuralFlag>
    )

    data class DetectionResult(
        val boots: Map<Long, BootVerdict>,
        /** wallMillis recorded under more than one boot: the duplicate census. */
        val duplicateStamps: Map<Long, Set<Long>>
    )

    /** `wall - elapsed` for a paired sample, null when the pair is unreadable. */
    fun offsetMillisOf(sample: ClockSample): Long? {
        val elapsedNanos = sample.elapsedNanos ?: return null
        if (sample.wallMillis <= 0L || elapsedNanos <= 0L) return null
        return sample.wallMillis - elapsedNanos / NANOS_PER_MILLISECOND
    }

    /**
     * Rejection distance for a boot whose MAD is [madMillis]: `k` normalized
     * MADs, never below the wall guard's tolerance, so millisecond jitter
     * between the two reads of a pair can never trip it.
     */
    fun rejectionThresholdMillis(madMillis: Long): Double =
        max(
            MAD_FACTOR * MAD_NORMALIZER * madMillis,
            WallClockGuard.TOLERANCE_MILLIS.toDouble()
        )

    fun detect(samples: List<ClockSample>): DetectionResult {
        if (samples.isEmpty()) return DetectionResult(emptyMap(), emptyMap())
        val collidedStamps = samples
            .groupBy({ it.wallMillis }, { it.bootCount })
            .mapValues { (_, boots) -> boots.toSet() }
            .filterValues { it.size > 1 }
        val collidedKeys = collidedStamps.keys

        // First pass: identify proven boot-default stamps.
        // A stamp is a proven default if it sits on the un-synced prefix of a
        // START_PLATEAU that was confirmed by duplicate census across boots.
        val jumpScale = WallClockGuard.TOLERANCE_MILLIS.toDouble()
        val provenDefaultStamps = mutableSetOf<Long>()
        for ((_, bootSamples) in samples.groupBy { it.bootCount }) {
            val paired = bootSamples.filter { offsetMillisOf(it) != null }.sortedBy { it.elapsedNanos }
            var split = -1
            for (i in 1 until paired.size) {
                if (abs(offsetMillisOf(paired[i])!! - offsetMillisOf(paired[i - 1])!!) > jumpScale) {
                    split = i
                    break
                }
            }
            if (split > 0) {
                val prefix = paired.subList(0, split)
                if (prefix.any { it.wallMillis in collidedKeys }) {
                    provenDefaultStamps.addAll(prefix.map { it.wallMillis })
                }
            }
        }

        val boots = samples
            .groupBy { it.bootCount }
            .mapValues { (boot, bootSamples) ->
                judgeBoot(boot, bootSamples, collidedKeys, provenDefaultStamps)
            }
        return DetectionResult(boots, collidedStamps)
    }

    private fun judgeBoot(
        bootCount: Long,
        bootSamples: List<ClockSample>,
        collidedStamps: Set<Long>,
        provenDefaultStamps: Set<Long>
    ): BootVerdict {
        val paired = bootSamples.filter { offsetMillisOf(it) != null }
        val flags = mutableSetOf<StructuralFlag>()
        if (bootSamples.any { it.wallMillis in collidedStamps }) {
            flags += StructuralFlag.DUPLICATE_STAMP
        }

        var median: Long? = null
        var mad: Long? = null
        val rejected = LinkedHashSet<ClockSample>()
        if (paired.size >= MIN_SAMPLES_PER_BOOT) {
            val offsets = paired.map { offsetMillisOf(it)!! }
            median = SessionClockAnchor.medianOffsetMillis(offsets)!!
            mad = SessionClockAnchor.medianOffsetMillis(offsets.map { abs(it - median) })!!
            val threshold = rejectionThresholdMillis(mad)
            paired.filterTo(rejected) { abs(offsetMillisOf(it)!! - median) > threshold }
        } else {
            flags += StructuralFlag.BELOW_MINIMUM_SAMPLES
        }

        // Structural arm: a flat run at the boot's start that then jumps past
        // the threshold is the un-synced prefix warming up, not an outlier to
        // discard. Consecutive steps define the run — no sample is the
        // reference — and the census names the guilty side, so a default
        // prefix that outweighs the good tail (median poisoned) still loses.
        // Without a census hit the shape stays a flag: the jump alone cannot
        // say which side ran on the default. Only the first jump splits; later
        // jumps stay the MAD arm's business. One sync per boot is the observed
        // shape; revisit when a boot shows two.
        val jumpScale = WallClockGuard.TOLERANCE_MILLIS.toDouble()
        val ordered = paired.sortedBy { it.elapsedNanos }
        var split = -1
        for (i in 1 until ordered.size) {
            if (abs(offsetMillisOf(ordered[i])!! - offsetMillisOf(ordered[i - 1])!!) > jumpScale) {
                split = i
                break
            }
        }
        if (split > 0) {
            flags += StructuralFlag.START_PLATEAU
            val prefix = ordered.subList(0, split)
            val tail = ordered.subList(split, ordered.size)
            if (prefix.any { it.wallMillis in collidedStamps || it.wallMillis in provenDefaultStamps }) {
                rejected.clear()
                rejected.addAll(prefix)
                if (tail.size >= MIN_SAMPLES_PER_BOOT) {
                    val tailOffsets = tail.map { offsetMillisOf(it)!! }
                    val tailMedian = SessionClockAnchor.medianOffsetMillis(tailOffsets)!!
                    val tailMad =
                        SessionClockAnchor.medianOffsetMillis(tailOffsets.map { abs(it - tailMedian) })!!
                    median = tailMedian
                    mad = tailMad
                    val tailThreshold = rejectionThresholdMillis(tailMad)
                    tail.filterTo(rejected) { abs(offsetMillisOf(it)!! - tailMedian) > tailThreshold }
                } else {
                    median = null
                    mad = null
                    flags += StructuralFlag.BELOW_MINIMUM_SAMPLES
                }
            }
        } else {
            // No intra-boot jump: if any samples sit on proven default stamps,
            // or if the ENTIRE paired run consists of duplicate stamps that
            // repeat across boots, they cannot attest a clean offset.
            val badDefaults = paired.filter { it.wallMillis in provenDefaultStamps }
            if (badDefaults.isNotEmpty()) {
                rejected.addAll(badDefaults)
                val clean = paired.filter { it !in badDefaults }
                if (clean.size >= MIN_SAMPLES_PER_BOOT) {
                    val cleanOffsets = clean.map { offsetMillisOf(it)!! }
                    val cleanMedian = SessionClockAnchor.medianOffsetMillis(cleanOffsets)!!
                    val cleanMad =
                        SessionClockAnchor.medianOffsetMillis(cleanOffsets.map { abs(it - cleanMedian) })!!
                    median = cleanMedian
                    mad = cleanMad
                    val cleanThreshold = rejectionThresholdMillis(cleanMad)
                    clean.filterTo(rejected) { abs(offsetMillisOf(it)!! - cleanMedian) > cleanThreshold }
                } else {
                    median = null
                    mad = null
                    flags += StructuralFlag.BELOW_MINIMUM_SAMPLES
                }
            } else if (paired.isNotEmpty() && paired.all { it.wallMillis in collidedStamps }) {
                // The entire boot sits on duplicate stamps that repeat across boots.
                // An un-anchored boot repeating a frozen RTC value is unattested.
                rejected.clear()
                rejected.addAll(paired)
                median = null
                mad = null
                flags += StructuralFlag.BELOW_MINIMUM_SAMPLES
            }
        }

        return BootVerdict(
            bootCount = bootCount,
            medianOffsetMillis = median,
            madMillis = mad,
            rejected = rejected.toList(),
            flags = flags
        )
    }
}
