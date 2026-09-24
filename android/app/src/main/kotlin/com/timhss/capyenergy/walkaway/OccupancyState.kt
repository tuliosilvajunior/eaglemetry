package com.timhss.capyenergy.walkaway

data class OccupancyState(
    val doorFrontLeftOpen: Boolean,
    val doorFrontRightOpen: Boolean,
    val doorRearLeftOpen: Boolean,
    val doorRearRightOpen: Boolean,
    val hoodOpen: Boolean,
    val trunkOpen: Boolean,
    val driverSeatbeltBuckled: Boolean,
    val passengerSeatbeltBuckled: Boolean,
) {
    val anyDoorOpen: Boolean =
        doorFrontLeftOpen || doorFrontRightOpen ||
            doorRearLeftOpen || doorRearRightOpen ||
            hoodOpen || trunkOpen

    val allDoorsClosed: Boolean get() = !anyDoorOpen

    fun toMap(): Map<String, Any?> = mapOf(
        "doorFrontLeftOpen" to doorFrontLeftOpen,
        "doorFrontRightOpen" to doorFrontRightOpen,
        "doorRearLeftOpen" to doorRearLeftOpen,
        "doorRearRightOpen" to doorRearRightOpen,
        "hoodOpen" to hoodOpen,
        "trunkOpen" to trunkOpen,
        "driverSeatbeltBuckled" to driverSeatbeltBuckled,
        "passengerSeatbeltBuckled" to passengerSeatbeltBuckled,
        "anyDoorOpen" to anyDoorOpen,
        "allDoorsClosed" to allDoorsClosed,
    )
}
