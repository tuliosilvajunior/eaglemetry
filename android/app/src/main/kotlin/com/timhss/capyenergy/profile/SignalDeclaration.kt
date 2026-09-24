package com.timhss.capyenergy.profile

/**
 * What a signal is, which decides what happens to it.
 *
 * A signal put through the wrong machinery gets the wrong treatment, not only
 * the wrong number.
 */
enum class SignalNature {
    /**
     * A quantity per unit time — power, current. It becomes an energy only by
     * integration, and an integral does not survive sampling, so a rate is
     * folded at the source rate and is never thinned.
     */
    RATE,

    /**
     * A value at an instant — state of charge, speed, altitude. It may be
     * written on a deadband, because a reader holds the last value between
     * samples and loses nothing but resolution.
     */
    STATE,

    /**
     * A transition — gear, plug, drive mode. Every change is written. A lost
     * transition is a wrong session, not a coarser one.
     */
    EVENT
}

/** The closed interval a reading must fall in to be accepted, in canonical units. */
data class SignalBand(val min: Double, val max: Double) {
    fun accepts(value: Double): Boolean = value.isFinite() && value in min..max
}

/**
 * How far a state signal must move before it is worth another row.
 *
 * It is declared **per series, not per signal**. The event log and the sample
 * series ask different questions of the same signal: the event log records what
 * a person would notice, the sample series records what a chart must draw.
 * State of charge needs 0.5 % for the first and 0.1 % for the second, and one
 * number cannot say both.
 *
 * A null band means the series does not carry this signal at all.
 */
data class SignalDeadbands(
    val event: Double? = null,
    val sample: Double? = null
)

/**
 * The raw reading and what the source said about when it was measured.
 *
 * The timestamp travels with the value because at least one transform needs it:
 * `BMSH_BAT_SOH` reads raw 999 with a zero source timestamp, which is a VHAL
 * default, and 999 also decodes to a legitimate 99.9 %. Nothing in the value
 * separates the two.
 */
data class RawReading(
    val value: Any?,
    val sourceTimestampNanos: Long? = null
)

/**
 * Everything one vehicle states about one signal.
 *
 * The declaration holds the **numbers**; the collection layer keeps its
 * judgement. `SignalEventPolicy` still decides that a quality change is always
 * worth a row, but it reads how far state of charge must drift from here.
 * Two deadbands for one signal is the class of defect this layer exists to
 * remove.
 */
data class SignalDeclaration(
    val key: SignalKey,
    val nature: SignalNature,

    /**
     * Raw source value to [SignalKey.unit], or null when the reading is not
     * trustworthy. Returning null is how a vehicle refuses a value it cannot
     * stand behind; the collection layer turns that into `UNAVAILABLE` rather
     * than into a measured zero.
     *
     * The default is the identity on an integer count, which is what an
     * enumeration and an unscaled probe need.
     */
    val transform: (RawReading) -> Any? = ::identityCount,

    /** The band [transform] output is accepted in. Null when the transform gates it itself. */
    val band: SignalBand? = null,

    val deadbands: SignalDeadbands = SignalDeadbands(),

    /**
     * The longest a state series may go without a row, in milliseconds.
     *
     * A deadband alone cannot say "this signal has not moved" apart from "this
     * signal stopped being read". The gap write is what separates them.
     */
    val maxGapMillis: Long? = null,

    /**
     * Every change is a transition worth recording, whatever the deadband says.
     *
     * True for a discrete control, and for a signal that is close to constant —
     * state of health moves over months, so each change is the degradation
     * history rather than jitter.
     */
    val everyChangeIsAnEvent: Boolean = false,

    /**
     * Whether this signal earns rows in the sample series.
     *
     * A signal is collected for more than one reason. It may drive a live
     * card, a session aggregate or an event, and never be drawn as a curve.
     * False keeps the signal on the bus and out of the series: the snapshot
     * writer stores everything it is handed, so a probe with no reader is a
     * row per movement forever, on the car and again in the cloud.
     *
     * Measured on `sample_2026_08`: seven such keys held 1 744 rows over
     * three days and answered no read path in either app.
     *
     * The flag is decided once, where the declarations are built:
     * `GeelyDeclarations` derives it from `UNSAMPLED_KEYS` (ADR-0010,
     * decision 1), so a declaration never opts out on its own.
     */
    val sampled: Boolean = true,

    /**
     * The tuple this signal belongs to, or null when it stands alone.
     *
     * Latitude, longitude and altitude are one measurement written as three
     * rows. They are written together or not at all, and the deadband is
     * evaluated on the group: keeping the latitude while dropping the longitude
     * reports a position the vehicle never held.
     */
    val group: String? = null,

    /**
     * For a [SignalNature.RATE] only: the rate its integral is folded at, in
     * hertz, and the measurement that justifies it.
     *
     * The rate may rise. It may not fall below the measured floor, and a
     * profile that declares one must name the evidence — see
         */
    val foldRateHz: Double? = null,
    val foldRateEvidence: String? = null
) {
    init {
        require(nature == SignalNature.RATE || foldRateHz == null) {
            "${key.name}: a fold rate belongs to a rate signal, not to a ${nature.name.lowercase()}"
        }
        require(foldRateHz == null || !foldRateEvidence.isNullOrBlank()) {
            "${key.name}: a declared fold rate must name the measurement that justifies it"
        }
    }

    /** [transform] with [band] applied, which is what a collector calls. */
    fun normalize(reading: RawReading): Any? {
        val transformed = transform(reading) ?: return null
        val band = band ?: return transformed
        val numeric = (transformed as? Number)?.toDouble() ?: return transformed
        return if (band.accepts(numeric)) transformed else null
    }
}

/** The identity on an integer count: no scale applied, and none assumed. */
fun identityCount(reading: RawReading): Any? = when (val value = reading.value) {
    is Int -> value
    is Number -> value.toInt()
    else -> value?.toString()?.toIntOrNull()
}

/** The raw reading as a float, with no scale applied. */
fun asFloat(reading: RawReading): Float? = when (val value = reading.value) {
    is Float -> value
    is Double -> value.toFloat()
    is Number -> value.toFloat()
    else -> value?.toString()?.toFloatOrNull()
}
