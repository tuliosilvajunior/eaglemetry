package com.timhss.capyenergy.vehicle

/**
 * Executes [VhalTestCommand]s and emits one log line per step.
 *
 * Every line is written through [log] so the operator can correlate the timeline
 * with `composeMcuData` lines from the VHAL — see the warning on [VhalTestCommand].
 */
class VhalTestRunner(
    private val access: VehiclePropertyAccess,
    private val log: (String) -> Unit,
    private val sleeper: (Long) -> Unit = { millis -> if (millis > 0) Thread.sleep(millis) },
) {
    /** @return a one-line summary, also emitted through [log]. */
    fun run(command: VhalTestCommand): String = when (command) {
        is VhalTestCommand.Ping -> ping()
        is VhalTestCommand.Stop -> emit("cmd=stop -> shutting down")
        is VhalTestCommand.Get -> get(command)
        is VhalTestCommand.Set -> set(command)
        is VhalTestCommand.Sweep -> sweep(command)
    }

    private fun ping(): String {
        val probe = access.readIntProperty(PING_PROPERTY_ID, VhalTestCommand.DEFAULT_AREA_ID)
        val state = if (probe == null) "UNAVAILABLE" else "READY"
        return emit(
            "cmd=ping carPropertyManager=$state probe=${PING_PROPERTY_ID.toHexId()} value=${probe.orDash()} " +
                "| reminder: readback proves the store only, grep composeMcuData for the CAN frame"
        )
    }

    private fun get(command: VhalTestCommand.Get): String {
        val value = access.readIntProperty(command.propertyId, command.areaId)
        return emit(
            "cmd=get prop=${command.propertyId.toHexId()}(${command.propertyId}) " +
                "area=${command.areaId} -> value=${value.orDash()}"
        )
    }

    private fun set(command: VhalTestCommand.Set): String {
        val before = access.readIntProperty(command.propertyId, command.areaId)
        val ok = access.setIntProperty(command.propertyId, command.areaId, command.value)
        val readback = access.readIntProperty(command.propertyId, command.areaId)
        return emit(
            "cmd=set prop=${command.propertyId.toHexId()}(${command.propertyId}) " +
                "area=${command.areaId} value=${command.value} " +
                "-> result=${ok.asResult()} before=${before.orDash()} readback=${readback.orDash()}"
        )
    }

    private fun sweep(command: VhalTestCommand.Sweep): String {
        val original = access.readIntProperty(command.propertyId, command.areaId)
        emit(
            "cmd=sweep prop=${command.propertyId.toHexId()}(${command.propertyId}) " +
                "area=${command.areaId} range=${command.from}..${command.to} " +
                "delayMs=${command.delayMillis} original=${original.orDash()}"
        )

        var applied = 0
        for (value in command.from..command.to) {
            val ok = access.setIntProperty(command.propertyId, command.areaId, value)
            if (ok) applied++
            val readback = access.readIntProperty(command.propertyId, command.areaId)
            emit(
                "sweep step prop=${command.propertyId.toHexId()} value=$value " +
                    "-> result=${ok.asResult()} readback=${readback.orDash()}"
            )
            sleeper(command.delayMillis)
        }

        // Restore even when steps failed: a partially applied sweep must not be
        // left on the cluster.
        val restored = if (original != null) {
            access.setIntProperty(command.propertyId, command.areaId, original).asResult()
        } else {
            "SKIPPED"
        }
        return emit(
            "cmd=sweep done prop=${command.propertyId.toHexId()} applied=$applied/" +
                "${command.to - command.from + 1} restore=$restored value=${original.orDash()}"
        )
    }

    private fun emit(line: String): String {
        log(line)
        return line
    }

    private fun Int?.orDash(): String = this?.toString() ?: "-"

    private fun Boolean.asResult(): String = if (this) "OK" else "FAIL"

    private fun Int.toHexId(): String = "0x" + toUInt().toString(16).padStart(8, '0')

    companion object {
        const val LOG_TAG = "VHALTEST"

        /**
         * SCREEN_LIGHT_AUTO — cluster brightness, routed to CAN frame 0x2A4. Used as
         * the ping probe because it is the one property confirmed end to end on this
         * car: dragging the Settings slider produced `composeMcuData prop=0x2140209a`
         * with `DATA=0x[02 a4 ...]`.
         */
        const val PING_PROPERTY_ID = 0x2140209A
    }
}
