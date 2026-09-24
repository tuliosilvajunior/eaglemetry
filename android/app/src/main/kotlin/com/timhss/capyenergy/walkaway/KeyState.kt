package com.timhss.capyenergy.walkaway

data class KeyState(
    val fobDetected: FobDetection,
    val rkeCommand: Int,
) {
    val keyInside: Boolean get() = fobDetected == FobDetection.INSIDE

    fun toMap(): Map<String, Any?> = mapOf(
        "fobDetected" to fobDetected.name,
        "rkeCommand" to rkeCommand,
        "keyInside" to keyInside,
    )
}

enum class FobDetection {
    UNKNOWN,
    INSIDE,
    OUTSIDE,
}
