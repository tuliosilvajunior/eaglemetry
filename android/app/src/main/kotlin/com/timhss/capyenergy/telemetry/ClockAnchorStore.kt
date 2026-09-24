package com.timhss.capyenergy.telemetry

import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * Boot-scoped anchor for the wall clock, learned from truth sources outside
 * the head unit's own unreliable clock.
 *
 * The car boots on the MCU firmware time and only syncs seconds later, so
 * every wall stamp before the sync is suspect. Inside one boot
 * `elapsedRealtimeNanos` is monotonic, therefore one trusted pair
 * `(wallMillis, elapsedNanos)` fixes the whole boot by exact arithmetic:
 * `wall(t) = anchorWall + (elapsed(t) - anchorElapsed)`. This store learns
 * that pair; it never rewrites a recorded row (retroactive correction is a
 * later task's sweeper, not this store).
 *
 * Sources, in order of preference:
 * - `SERVER_DATE`: the HTTP `Date` header of the first successful cloud
 *   call ([com.timhss.capyenergy.telemetry.sync.HttpCloudSink] offers it).
 *   Free on every paired car, out-of-band truth.
 * - `GPS_FIX`: `location.time` + `elapsedRealtimeNanos` from
 *   [LocationSignalProvider], offered on every fix. The receiver's own
 *   clock, not the head unit's.
 *
 * Anchor rule (a Date that disagrees with what is known is hostile input,
 * never truth):
 * - No learned anchor and no reference: the first Date of the boot is
 *   stored, but the boot stays PENDING — one source never leaves PENDING.
 * - A Date that agrees with the learned anchor (or the reference median,
 *   when one was set) within [WallClockGuard.TOLERANCE_MILLIS] confirms it.
 * - Anything else is rejected: a shifted Date resolves nothing.
 *
 * Leaving PENDING (a *learned* anchor) needs two independent sources or
 * history, never one source alone:
 * - Date or GPS corroborated by history: agrees with the reference offset
 *   (the session median the detector will feed via [setReferenceOffset])
 *   within [WallClockGuard.TOLERANCE_MILLIS]; learns at once, no wait.
 * - First boot without history: `|Date - GPS| < [CORROBORATION_TOLERANCE_MILLIS]`,
 *   compared as offsets (`wall - elapsed`), so the two readings need not be
 *   simultaneous — the offset is constant within a boot.
 * - No source ever corroborates itself without history: a second Date or a
 *   second GPS from the same origin does NOT leave PENDING. Two independent
 *   sources (`SERVER_DATE` and `GPS_FIX`) must agree.
 *
 * The anchor is per boot: `elapsedRealtimeNanos` restarts on reboot, so an
 * offer whose elapsed drops significantly (more than [REBOOT_THRESHOLD_NANOS])
 * clears the boot state, including any reference offset, because offsets
 * (`wall - elapsed`) cannot be compared across different boots.
 *
 * Threading: a synchronized singleton. The uploader's IO thread offers
 * server Dates while the collector thread offers GPS fixes; the learned
 * anchor, once set, never moves within a boot.
 */
object ClockAnchorStore {
    enum class Source {
        SERVER_DATE,
        GPS_FIX,
    }

    /** One trusted pairing of wall time with the monotonic axis. */
    data class Anchor(
        val wallMillis: Long,
        val elapsedNanos: Long,
        val source: Source,
    )

    /**
     * Two truth sources corroborate when their offsets agree inside this.
     * Strict: exactly at the boundary does NOT corroborate.
     */
    const val CORROBORATION_TOLERANCE_MILLIS = 5 * 60 * 1_000L

    /**
     * Threshold to detect reboot. Inter-thread scheduling or GPS hardware
     * latency can produce sub-second negative elapsed differences. A drop
     * greater than 10 seconds signals a system reboot.
     */
    const val REBOOT_THRESHOLD_NANOS = 10 * 1_000_000_000L

    private const val NANOS_PER_MILLISECOND = 1_000_000L

    @Volatile
    private var serverDate: Anchor? = null

    @Volatile
    private var gpsFix: Anchor? = null

    @Volatile
    private var learned: Anchor? = null

    /**
     * Fired once when a boot leaves PENDING (first learn), and again when
     * the reference offset promotes a stored candidate. G1 schedules the
     * boot sweep from here, off the caller thread. Cleared with the boot.
     */
    private var learnedListeners: MutableList<() -> Unit> = mutableListOf()

    /**
     * Registers a one-boot callback for the learn transition. The callback
     * runs on the thread that learns the anchor — the subscriber moves it
     * off (G1 posts it to the telemetry write queue). If the boot already
     * learned, the callback runs immediately so a late subscriber still
     */
    @Synchronized
    fun onLearned(listener: () -> Unit) {
        if (learned != null) {
            listener()
        } else {
            learnedListeners.add(listener)
        }
    }

    /** In-boot reference offset (session median); set by the detector hookup. */
    @Volatile
    private var referenceOffsetMillis: Long? = null

    @Volatile
    private var maxElapsedNanos: Long = 0L

    /**
     * Offers a server `Date` reading. Returns true when stored or consistent
     * with the learned anchor, false when rejected (non-positive, or
     * disagreeing with what this boot already trusts).
     */
    @Synchronized
    fun offerServerDate(serverWallMillis: Long, elapsedNanos: Long): Boolean {
        if (serverWallMillis <= 0L || elapsedNanos <= 0L) return false
        onOfferLocked(elapsedNanos)
        val candidate = Anchor(serverWallMillis, elapsedNanos, Source.SERVER_DATE)
        val known = learned
        if (known != null) {
            if (!agreesWith(candidate, offsetOf(known), WallClockGuard.TOLERANCE_MILLIS)) return false
            return true
        }
        val reference = referenceOffsetMillis
        if (reference != null) {
            if (!agreesWith(candidate, reference, WallClockGuard.TOLERANCE_MILLIS)) return false
            serverDate = candidate
            learned = candidate
            fireLearnedLocked()
            return true
        }
        val first = serverDate
        if (first == null) {
            serverDate = candidate
            tryLearnLocked()
            return true
        }
        val agreesWithFirst = agreeOffsets(candidate, first, CORROBORATION_TOLERANCE_MILLIS)
        val gps = gpsFix
        val agreesWithGps = gps != null && agreeOffsets(candidate, gps, CORROBORATION_TOLERANCE_MILLIS)

        if (!agreesWithFirst && !agreesWithGps) return false
        if (agreesWithGps) {
            serverDate = candidate
            learned = candidate
            fireLearnedLocked()
            return true
        }

        if (agreesWithFirst) {
            tryLearnLocked()
            return true
        }

        return false
    }

    /**
     * Offers a GPS fix time. Same contract as [offerServerDate]; a GPS fix
     * alone never leaves the boot PENDING without history — it waits for a
     * Date to corroborate (or corroborates a Date already stored).
     */
    @Synchronized
    fun offerGpsFix(gpsWallMillis: Long, elapsedNanos: Long): Boolean {
        if (gpsWallMillis <= 0L || elapsedNanos <= 0L) return false
        onOfferLocked(elapsedNanos)
        val candidate = Anchor(gpsWallMillis, elapsedNanos, Source.GPS_FIX)
        val known = learned
        if (known != null) {
            if (!agreesWith(candidate, offsetOf(known), WallClockGuard.TOLERANCE_MILLIS)) return false
            return true
        }
        val reference = referenceOffsetMillis
        if (reference != null) {
            if (!agreesWith(candidate, reference, WallClockGuard.TOLERANCE_MILLIS)) return false
            gpsFix = candidate
            learned = candidate
            fireLearnedLocked()
            return true
        }
        val first = gpsFix
        if (first == null) {
            gpsFix = candidate
            tryLearnLocked()
            return true
        }
        val agreesWithFirst = agreeOffsets(candidate, first, CORROBORATION_TOLERANCE_MILLIS)
        val date = serverDate
        val agreesWithDate = date != null && agreeOffsets(candidate, date, CORROBORATION_TOLERANCE_MILLIS)

        if (!agreesWithFirst && !agreesWithDate) return false
        if (agreesWithDate) {
            gpsFix = candidate
            learned = date
            fireLearnedLocked()
            return true
        }

        if (agreesWithFirst) {
            tryLearnLocked()
            return true
        }

        return false
    }

    /**
     * Sets the in-boot reference offset (per-boot median from session
     * history). Null clears it. A stored candidate that agrees with a newly
     * set reference learns at once. Wired by the detector hookup; null until
     * then, which is exactly the first-boot-no-history case.
     */
    @Synchronized
    fun setReferenceOffset(medianOffsetMillis: Long?) {
        referenceOffsetMillis = medianOffsetMillis
        if (medianOffsetMillis == null || learned != null) return
        val date = serverDate
        if (date != null && agreesWith(date, medianOffsetMillis, WallClockGuard.TOLERANCE_MILLIS)) {
            learned = date
            fireLearnedLocked()
            return
        }
        val gps = gpsFix
        if (gps != null && agreesWith(gps, medianOffsetMillis, WallClockGuard.TOLERANCE_MILLIS)) {
            learned = gps
            fireLearnedLocked()
        }
    }

    /** Best pair known this boot: learned, else first Date, else first GPS. */
    @Synchronized
    fun anchor(): Anchor? = learned ?: serverDate ?: gpsFix

    /** True once two sources (or history) corroborated: the boot left PENDING. */
    @Synchronized
    fun isLearned(): Boolean = learned != null

    /** Clears everything, including the in-boot reference. Test hook. */
    @Synchronized
    fun reset() {
        clearBootLocked()
    }

    private fun clearBootLocked() {
        serverDate = null
        gpsFix = null
        learned = null
        referenceOffsetMillis = null
        maxElapsedNanos = 0L
        learnedListeners = mutableListOf()
    }

    /**
     * Reboot signal: elapsed runs backwards across a reboot. Normal GPS fix
     * latency or inter-thread scheduling can produce small backward steps;
     * only a drop larger than [REBOOT_THRESHOLD_NANOS] signals a real reboot.
     */
    private fun onOfferLocked(elapsedNanos: Long) {
        if (maxElapsedNanos > 0L && maxElapsedNanos - elapsedNanos > REBOOT_THRESHOLD_NANOS) {
            clearBootLocked()
            maxElapsedNanos = elapsedNanos
        } else if (elapsedNanos > maxElapsedNanos) {
            maxElapsedNanos = elapsedNanos
        }
    }

    private fun tryLearnLocked() {
        if (learned != null || referenceOffsetMillis != null) return
        val date = serverDate ?: return
        val gps = gpsFix ?: return
        if (agreeOffsets(date, gps, CORROBORATION_TOLERANCE_MILLIS)) {
            learned = date
            fireLearnedLocked()
        }
    }

    private fun fireLearnedLocked() {
        val pending = learnedListeners.toList()
        learnedListeners.clear()
        for (listener in pending) {
            runCatching { listener() }
        }
    }

    private fun offsetOf(anchor: Anchor): Long =
        anchor.wallMillis - anchor.elapsedNanos / NANOS_PER_MILLISECOND

    private fun agreesWith(anchor: Anchor, offsetMillis: Long, toleranceMillis: Long): Boolean =
        Math.abs(offsetOf(anchor) - offsetMillis) <= toleranceMillis

    private fun agreeOffsets(first: Anchor, second: Anchor, toleranceMillis: Long): Boolean =
        Math.abs(offsetOf(first) - offsetOf(second)) < toleranceMillis

    /**
     * Parses an HTTP `Date` header value to millis. Returns null when the
     * header is absent, blank, malformed, or non-positive — a hostile header
     * never throws, it just yields no reading. A well-formed but wrong Date
     * parses fine; the anchor rule (not the parser) rejects it.
     */
    fun parseHttpDateHeader(value: String?): Long? {
        if (value.isNullOrBlank()) return null
        val text = value.trim()
        for (pattern in HTTP_DATE_FORMATS) {
            val parsed = try {
                val format = SimpleDateFormat(pattern, Locale.US)
                format.timeZone = TimeZone.getTimeZone("GMT")
                format.isLenient = false
                format.parse(text)
            } catch (_: Exception) {
                null
            }
            if (parsed != null && parsed.time > 0L) return parsed.time
        }
        return null
    }

    private val HTTP_DATE_FORMATS = listOf(
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    )
}
