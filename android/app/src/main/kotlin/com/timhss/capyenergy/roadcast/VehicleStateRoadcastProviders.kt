package com.timhss.capyenergy.roadcast

import com.timhss.capyenergy.roadcast.RoadcastSignalProvider
import com.timhss.capyenergy.roadcast.RoadcastSnapshot

/**
 * A boolean supplied by the vehicle bus. UNKNOWN is deliberately distinct from
 * false: absent, invalid or stale data must never imply that a door is open.
 */
enum class KnownBoolean {
    TRUE,
    FALSE,
    UNKNOWN,
}

data class OccupancyReading(
    val frontLeftOpen: KnownBoolean,
    val frontRightOpen: KnownBoolean,
    val rearLeftOpen: KnownBoolean,
    val rearRightOpen: KnownBoolean,
    val hoodOpen: KnownBoolean,
    val trunkOpen: KnownBoolean,
    val driverSeatbeltBuckled: KnownBoolean,
    val passengerSeatbeltBuckled: KnownBoolean,
) {
    /** Delta-style door signals may be absent while closed; only OPEN blocks. */
    val noClosureIsOpen: Boolean
        get() = listOf(
            frontLeftOpen,
            frontRightOpen,
            rearLeftOpen,
            rearRightOpen,
            hoodOpen,
            trunkOpen,
        ).none { it == KnownBoolean.TRUE }
}

/** Pure Roadcast projection. It owns no JNI client, scheduler or listener. */
object OccupancyRoadcastProvider : RoadcastSignalProvider<OccupancyReading> {
    const val FRONT_LEFT_DOOR = "BCM_FrontLeftDoorAjarStatus"
    const val FRONT_RIGHT_DOOR = "BCM_FrontRightDoorAjarStatus"
    const val REAR_LEFT_DOOR = "BCM_RearLeftDoorAjarStatus"
    const val REAR_RIGHT_DOOR = "BCM_RearRightDoorAjarStatus"
    const val HOOD = "BCM_HoodAjarStatus"
    const val TRUNK = "BCM_TrunkAjarStatus"
    const val DRIVER_BELT = "ACU_DrvSeatbeltBucklestatus"
    const val PASSENGER_BELT_WARNING = "ACU_PassSeatbeltWarning"

    override val requiredSignals: Set<String> = setOf(
        FRONT_LEFT_DOOR,
        FRONT_RIGHT_DOOR,
        REAR_LEFT_DOOR,
        REAR_RIGHT_DOOR,
        HOOD,
        TRUNK,
        DRIVER_BELT,
        PASSENGER_BELT_WARNING,
    )

    override fun read(snapshot: RoadcastSnapshot): OccupancyReading = OccupancyReading(
        frontLeftOpen = active(snapshot, FRONT_LEFT_DOOR),
        frontRightOpen = active(snapshot, FRONT_RIGHT_DOOR),
        rearLeftOpen = active(snapshot, REAR_LEFT_DOOR),
        rearRightOpen = active(snapshot, REAR_RIGHT_DOOR),
        hoodOpen = active(snapshot, HOOD),
        trunkOpen = active(snapshot, TRUNK),
        // On this vehicle, 1 means unbuckled for the driver's buckle signal.
        driverSeatbeltBuckled = invert(active(snapshot, DRIVER_BELT)),
        // The old provider interpreted warning == 0 as buckled. Preserve that
        // decoding only as a degraded observation until it is validated on-car.
        passengerSeatbeltBuckled = invert(active(snapshot, PASSENGER_BELT_WARNING)),
    )

    private fun active(snapshot: RoadcastSnapshot, name: String): KnownBoolean {
        val sample = snapshot.sample(name) ?: return KnownBoolean.UNKNOWN
        if (!sample.valid) return KnownBoolean.UNKNOWN
        return if (sample.physical >= 1.0) KnownBoolean.TRUE else KnownBoolean.FALSE
    }

    private fun invert(value: KnownBoolean): KnownBoolean = when (value) {
        KnownBoolean.TRUE -> KnownBoolean.FALSE
        KnownBoolean.FALSE -> KnownBoolean.TRUE
        KnownBoolean.UNKNOWN -> KnownBoolean.UNKNOWN
    }
}

/**
 * Raw key/FOB facts from the same frame as occupancy. Fob inside/outside is a
 * temporal interpretation and belongs in a reducer, not this stateless provider.
 */
data class KeyObservation(
    val fobPresent: KnownBoolean,
    val rkeCommand: Long?,
    val frontLeftOpen: KnownBoolean,
    val frontRightOpen: KnownBoolean,
    val rearLeftOpen: KnownBoolean,
    val rearRightOpen: KnownBoolean,
    val hoodOpen: KnownBoolean,
    val trunkOpen: KnownBoolean,
)

object KeyRoadcastProvider : RoadcastSignalProvider<KeyObservation> {
    const val FOB_NUM = "PEPS_FOB_NUM"
    const val RKE_COMMAND = "PEPS_RKECommand"

    override val requiredSignals: Set<String> = setOf(
        FOB_NUM,
        RKE_COMMAND,
        OccupancyRoadcastProvider.FRONT_LEFT_DOOR,
        OccupancyRoadcastProvider.FRONT_RIGHT_DOOR,
        OccupancyRoadcastProvider.REAR_LEFT_DOOR,
        OccupancyRoadcastProvider.REAR_RIGHT_DOOR,
        OccupancyRoadcastProvider.HOOD,
        OccupancyRoadcastProvider.TRUNK,
    )

    override fun read(snapshot: RoadcastSnapshot): KeyObservation = KeyObservation(
        fobPresent = active(snapshot, FOB_NUM),
        rkeCommand = snapshot.sample(RKE_COMMAND)?.takeIf { it.valid }?.raw,
        frontLeftOpen = active(snapshot, OccupancyRoadcastProvider.FRONT_LEFT_DOOR),
        frontRightOpen = active(snapshot, OccupancyRoadcastProvider.FRONT_RIGHT_DOOR),
        rearLeftOpen = active(snapshot, OccupancyRoadcastProvider.REAR_LEFT_DOOR),
        rearRightOpen = active(snapshot, OccupancyRoadcastProvider.REAR_RIGHT_DOOR),
        hoodOpen = active(snapshot, OccupancyRoadcastProvider.HOOD),
        trunkOpen = active(snapshot, OccupancyRoadcastProvider.TRUNK),
    )

    private fun active(snapshot: RoadcastSnapshot, name: String): KnownBoolean {
        val sample = snapshot.sample(name) ?: return KnownBoolean.UNKNOWN
        if (!sample.valid) return KnownBoolean.UNKNOWN
        return if (sample.raw >= 1L) KnownBoolean.TRUE else KnownBoolean.FALSE
    }
}

