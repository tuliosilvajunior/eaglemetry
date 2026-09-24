package com.timhss.capyenergy.vehicle

/**
 * Read/write access to raw VHAL properties, narrow enough to fake in unit tests.
 *
 * Implemented by [VehiclePropertyHelper], which swallows the underlying
 * exception and returns `null`/`false`. The exception detail (SecurityException,
 * IllegalArgumentException, CarNotConnectedException) is logged under the
 * `VehiclePropertyHelper` tag, so diagnose failures by grepping both tags.
 */
interface VehiclePropertyAccess {
    fun readIntProperty(propertyId: Int, areaId: Int): Int?
    fun setIntProperty(propertyId: Int, areaId: Int, value: Int): Boolean
}

/**
 * Raw command arguments, already extracted from the broadcast Intent.
 *
 * Kept free of Android types so [VhalTestCommand.parse] is unit-testable.
 */
data class VhalTestRequest(
    val op: String?,
    val propertyId: Int? = null,
    val propertyIdHex: String? = null,
    val areaId: Int? = null,
    val value: Int? = null,
    val from: Int? = null,
    val to: Int? = null,
    val delayMillis: Int? = null,
)

/**
 * An adb-driven VHAL test command.
 *
 * WARNING ON INTERPRETING RESULTS: `result=OK` plus a matching `readback` proves
 * only that the value reached the local VehiclePropertyStore. It does NOT prove a
 * CAN frame left the VHAL — a write over the VehicleEmulator socket produces
 * exactly that same evidence while composing no frame at all. The proof is the
 * VHAL's own log line:
 *
 *     adb logcat | grep composeMcuData
 *     D CmdSmdManager: ---VehicleHal composeMcuData --- prop=0x2140209a,
 *       cmdsmd=0x1000, dataLen = 13, DATA=0x[02 a4 40 00 01 00 00 00 00 20 00 00 00]
 *                                              ^^^^^ CAN id
 *
 * Full context in the systemEX2 notes, `ESCRITA_NO_MCU_EX2.md`. That file is
 * not in this repository; it is part of the separate `apk_exploration`
 * research repository.
 */
sealed class VhalTestCommand {
    /** Reports whether the CarPropertyManager connection is usable. */
    object Ping : VhalTestCommand()

    /** Shuts the test service down and releases the Car connection. */
    object Stop : VhalTestCommand()

    data class Get(val propertyId: Int, val areaId: Int) : VhalTestCommand()

    data class Set(val propertyId: Int, val areaId: Int, val value: Int) : VhalTestCommand()

    /**
     * Writes every value in [from]..[to], holding each for [delayMillis], then
     * restores whatever the property held before the sweep. Used to discover
     * enums that have no named enumerators in the VHAL debug info.
     */
    data class Sweep(
        val propertyId: Int,
        val areaId: Int,
        val from: Int,
        val to: Int,
        val delayMillis: Long,
    ) : VhalTestCommand()

    companion object {
        const val DEFAULT_AREA_ID = 0
        const val DEFAULT_DELAY_MILLIS = 2_500L
        const val MAX_DELAY_MILLIS = 10_000L
        const val MAX_SWEEP_STEPS = 64

        val SUPPORTED_OPS = listOf("ping", "get", "set", "sweep", "stop")

        /**
         * @throws IllegalArgumentException when the command is unusable. Rejecting
         * here — before any Car call — keeps a malformed command from writing a
         * half-applied state to the vehicle.
         */
        fun parse(request: VhalTestRequest): VhalTestCommand {
            val op = request.op?.trim()?.lowercase()
            require(!op.isNullOrEmpty()) { "missing op; supported: ${SUPPORTED_OPS.joinToString()}" }

            return when (op) {
                "ping" -> Ping
                "stop" -> Stop
                "get" -> Get(requirePropertyId(request), areaId(request))
                "set" -> Set(
                    propertyId = requirePropertyId(request),
                    areaId = areaId(request),
                    value = requireNotNull(request.value) { "op=set requires value" },
                )
                "sweep" -> sweep(request)
                else -> throw IllegalArgumentException(
                    "unknown op '$op'; supported: ${SUPPORTED_OPS.joinToString()}"
                )
            }
        }

        private fun sweep(request: VhalTestRequest): Sweep {
            val from = requireNotNull(request.from) { "op=sweep requires from" }
            val to = requireNotNull(request.to) { "op=sweep requires to" }
            require(to >= from) { "op=sweep requires to >= from (got from=$from to=$to)" }
            val steps = to - from + 1
            require(steps <= MAX_SWEEP_STEPS) {
                "op=sweep spans $steps values, limit is $MAX_SWEEP_STEPS"
            }

            val delay = request.delayMillis?.toLong() ?: DEFAULT_DELAY_MILLIS
            require(delay in 0..MAX_DELAY_MILLIS) {
                "delayMs must be 0..$MAX_DELAY_MILLIS (got $delay)"
            }

            return Sweep(
                propertyId = requirePropertyId(request),
                areaId = areaId(request),
                from = from,
                to = to,
                delayMillis = delay,
            )
        }

        private fun areaId(request: VhalTestRequest): Int = request.areaId ?: DEFAULT_AREA_ID

        /**
         * Accepts either `--ei prop <decimal>` or `--es propHex 0x2140a384`, since
         * the property catalogues are written in hex but `am broadcast` only passes
         * integers as decimal.
         */
        private fun requirePropertyId(request: VhalTestRequest): Int {
            request.propertyId?.let { return it }

            val hex = request.propertyIdHex?.trim()
            require(!hex.isNullOrEmpty()) { "op=${request.op} requires prop or propHex" }
            val digits = hex.removePrefix("0x").removePrefix("0X")
            val parsed = digits.toLongOrNull(radix = 16)
                ?: throw IllegalArgumentException("propHex '$hex' is not hexadecimal")
            require(parsed in 1..0xFFFFFFFFL) { "propHex '$hex' is out of range" }
            return parsed.toInt()
        }
    }
}
