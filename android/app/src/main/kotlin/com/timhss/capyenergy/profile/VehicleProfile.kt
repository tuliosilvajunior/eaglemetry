package com.timhss.capyenergy.profile

/**
 * What a vehicle can do, as opposed to what it measures.
 *
 * The shell reads these to decide which destinations exist. A profile that
 * fixed collection and said nothing about capability would leave the user
 * interface offering a surface the vehicle cannot serve, which is the same
 * defect as showing a value it never sent.
 */
enum class VehicleCapability {
    /** A decoded bus is reachable, so a rate can be folded above the frame rate. */
    BUS_RATE_TRANSPORT,

    /** The vehicle publishes a signed pack power, so a trip has a measured energy. */
    MEASURED_PACK_POWER,

    /** Cabin climate is controllable from the app. */
    CLIMATE_CONTROL,

    /** A phone can be projected onto the head unit. */
    PHONE_PROJECTION,

    /** A receiver answers with a position and a course over ground. */
    LOCATION
}

/** The pack facts this app is told, never the ones it reads from the vehicle. */
data class BatterySpec(
    /** Default capacity in Wh, used when Settings holds none. */
    val defaultCapacityWh: Double,
    /** The band a stated capacity must fall in to be accepted. */
    val acceptedCapacityWh: ClosedFloatingPointRange<Double>
)

/** How a vehicle spells the gear positions this product reasons about. */
data class GearCodes(
    val park: Int,
    val reverse: Int,
    val neutral: Int,
    val drive: Int
) {
    /** True when [raw] carries the park bit. The vehicle reports a mask, not an index. */
    fun isPark(raw: Int): Boolean = (raw and park) != 0

    fun isDrive(raw: Int): Boolean = (raw and drive) != 0
}

/**
 * How a vehicle spells the charging states and plug states this product reasons
 * about.
 *
 * Alternating and direct current are kept apart because the charge limit acts
 * on a different soft switch for each, and applying the wrong one leaves the
 * vehicle charging past the target with the app reporting that it stopped.
 */
data class ChargeCodes(
    val chargingAc: Set<Int>,
    val chargingDc: Set<Int>,
    /** Every state that means charging has stopped, whatever the plug does. */
    val finished: Set<Int>,
    /** Every plug state that means something is physically connected. */
    val connected: Set<Int>
) {
    /** Every state that means current is flowing into the pack. */
    val charging: Set<Int> get() = chargingAc + chargingDc

    fun isCharging(state: Int?): Boolean = state != null && state in charging

    fun isFinished(state: Int?): Boolean = state != null && state in finished

    fun isConnected(plug: Int?): Boolean = plug != null && plug in connected
}

/** Which session a signal is a measurement of, rather than a leftover from. */
enum class SessionKind { TRIP, CHARGE, PARKED }

/**
 * One vehicle, stated once.
 *
 * Above this interface nothing may name a VHAL property, a CAN frame or a
 * vendor constant. That boundary is what a second vehicle needs, and it is
 * asserted by `VehicleProfileBoundaryTest`.
 */
interface VehicleProfile {

    /** Stable identifier for this profile. It is not the vehicle's identity. */
    val id: String

    /** What every signal this vehicle answers is, and how to read it. */
    val declarations: Map<SignalKey, SignalDeclaration>

    /** Which keys are reached over the property surface, and where. */
    val propertySignals: List<SignalSpec>

    /** Which keys are reached over the bus transport, and under what name. */
    val busSignals: Map<SignalKey, BusBinding>

    val capabilities: Set<VehicleCapability>

    val battery: BatterySpec

    val gearCodes: GearCodes

    val chargeCodes: ChargeCodes

    /**
     * The keys that answer one question, best source first.
     *
     * The outside temperature has two sources on this vehicle and they are not
     * equally trustworthy, so the order is a statement about the vehicle rather
     * than a preference of the reader.
     */
    fun trustOrder(key: SignalKey): List<SignalKey>

    /**
     * Whether a reading of [key] describes a session of [kind].
     *
     * A drivetrain signal recorded during a charge, or a charger signal
     * recorded during a drive, is the last value that ECU sent before it went
     * quiet — not a measurement of the session it lands in. This rule lived in
     * comments inside the frame writer, where a second vehicle could not
     * reach it.
     */
    fun recordsDuring(key: SignalKey, kind: SessionKind): Boolean

    /**
     * The signals whose change belongs to the session it happened in.
     *
     * A trip's event list is read by a person, so the question is not "did
     * this value move" but "would somebody recognise this as something that
     * happened on the drive". A gear, a light, the cruise control and the
     * charge state are such things. The odometer is not: it moves constantly,
     * it is a state with a curve of its own in the sample series, and one
     * recorded 17-minute trip produced 57 of them — enough to bury the five
     * rows that describe the drive.
     *
     * Since issue 226, a signal not named here is not written on its own
     * account: it lives in the in-memory recent-events buffer only, and
     * reaches the database only if something else stamps it with a session.
     * Adding a signal to a trip's story is therefore still one line in this
     * set, and nothing else changes.
     */
    val sessionEventKeys: Set<SignalKey>

    fun declarationFor(key: SignalKey): SignalDeclaration? = declarations[key]

    /** Whether a change of [key] is part of a session's story. */
    fun isSessionEvent(key: SignalKey): Boolean = key in sessionEventKeys

    /**
     * Whether the plug type code means DC fast charge.
     *
     * The head unit publishes the plug as a raw code and the layer above must
     * not decode it. A second vehicle changes the code in the profile, not in
     * the assembly that reads it.
     */
    fun isDcFastCharge(plugTypeValue: Any?): Boolean

    /**
     * Where a key lives on the property surface, or null when it is not there.
     *
     * The one legitimate reader is a diagnostic that reports which address an
     * answer came from. Nothing that computes may need this.
     */
    fun propertyIdFor(key: SignalKey): Int? =
        propertySignals.firstOrNull { it.signalId == key }?.propertyId

    fun has(capability: VehicleCapability): Boolean = capability in capabilities
}

/**
 * Where a key lives on the property surface, and how to keep it fresh.
 *
 * This is a binding, not a signal: it says how one vehicle answers a key. The
 * key, its unit, its nature and its bands are in [SignalDeclaration], which is
 * where a reader looks.
 */
data class SignalSpec(
    val signalId: SignalKey,
    val propertyId: Int,
    val areaId: Int = 0,
    val preferredSampleRate: Float = SENSOR_RATE_ONCHANGE,
    val pollingIntervalMillis: Long = 1_000L,
    val ecarxLogicalId: Int? = null,
    /**
     * Which wrapper domain the logical id lives in. Charging and energy ids are
     * function ids; the key-state ones are sensor ids and must resolve through
     * the sensor type.
     */
    val ecarxIdType: Int = ECARX_ID_TYPE_FUNCTION,
    val adaptEcarxValue: Boolean = false,
    /**
     * Momentary key events: a press flashes non-zero then reverts to 0 within
     * milliseconds. Latch the last non-zero value so it stays visible, and log
     * every raw callback for live diagnosis.
     */
    val keyEventLatch: Boolean = false,
    /**
     * Whether to fall back to periodic polling when the on-change callback
     * fails to register. For a momentary key event polling is useless — it
     * samples the resting zero almost always — and it hides the failure.
     */
    val pollingFallback: Boolean = true,
    /** Log every raw callback for this signal, to prove on a live drive that it pushes. */
    val rawLog: Boolean = false,
    /**
     * The property-store address, kept as source-research metadata when it
     * differs from [propertyId].
     *
     * `null` means the two sources use the same address. [RAM_ABSENT] means the
     * property is not in the store at all and only the property service
     * synthesises it, so there is nowhere to migrate to.
     */
    val ramPropertyId: Int? = null
) {
    /** Where to read this property in the store, or null when it is not there. */
    val ramAddress: Int?
        get() = when (ramPropertyId) {
            null -> propertyId
            RAM_ABSENT -> null
            else -> ramPropertyId
        }

    companion object {
        /** No property id is 0, so it serves as the sentinel. */
        const val RAM_ABSENT = 0
    }
}

/**
 * Where a key lives on the bus, and what travels with it.
 *
 * [invalidCompanion] is the bus's own claim that the reading is not
 * trustworthy. It is honoured only when the vehicle actually sends it: a
 * companion that has never been published carries no claim about anything, and
 * treating its default as a refusal would suppress a good measurement for ever.
 *
 * [requiresCalibration] is false only for an enumerated count, whose decode is
 * the identity. A daemon has no scale to verify there, so demanding one would
 * reject every sample.
 */
data class BusBinding(
    val signalName: String,
    val invalidCompanion: String? = null,
    val requiresCalibration: Boolean = true,
    /** Kept beside the scaled value when the scale is assumed rather than verified. */
    val keepRawCount: Boolean = false
)

/**
 * Mirrors `CarPropertyManager.SENSOR_RATE_ONCHANGE`, so layer 0 does not depend
 * on the car framework. A profile is plain data and must stay testable without
 * an Android device.
 */
const val SENSOR_RATE_ONCHANGE = 0f

/** `IWrapper.WrappedIdType` function domain. Charging and energy ids live here. */
const val ECARX_ID_TYPE_FUNCTION = 2

/** `IWrapper.WrappedIdType` sensor domain. The key and usage-mode ids live here. */
const val ECARX_ID_TYPE_SENSOR = 3
