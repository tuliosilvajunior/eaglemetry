package com.timhss.capyenergy.telemetry.pairing

/**
 * Pure mapping from pairing domain results to the method-channel contract maps.
 *
 * No I/O, no SharedPreferences, no polling — just data transformation.
 * This is what the contract tests should target; proving the maps here proves
 * the bridge cannot silently regress to a literal-to-literal test.
 */
object PairingStateMapper {

    fun startToMap(result: PairingStartResult, vehicleId: String): Map<String, Any?> =
        mapOf(
            "status" to "pending",
            "userCode" to result.userCode,
            "expiresAt" to result.expiresAt,
            "vehicleId" to vehicleId
        )

    fun approvedToMap(vehicleId: String, accountId: String?): Map<String, Any?> =
        mapOf(
            "status" to "approved",
            "vehicleId" to vehicleId,
            "accountId" to accountId
        )

    fun pendingToMap(pending: PairingStartResult?, vehicleId: String): Map<String, Any?> =
        mapOf(
            "status" to "pending",
            "userCode" to pending?.userCode,
            "expiresAt" to pending?.expiresAt,
            "vehicleId" to vehicleId
        )

    fun registeredToMap(): Map<String, Any?> =
        mapOf(
            "status" to "registered",
            "reason" to "registered"
        )

    fun revokedToMap(): Map<String, Any?> =
        mapOf(
            "status" to "revoked",
            "reason" to "revoked"
        )

    fun expiredToMap(): Map<String, Any?> =
        mapOf(
            "status" to "expired",
            "reason" to "expired"
        )

    fun rejectedToMap(): Map<String, Any?> =
        mapOf(
            "status" to "rejected",
            "reason" to "rejected"
        )

    fun invalidCodeToMap(): Map<String, Any?> =
        mapOf(
            "status" to "invalidCode",
            "reason" to "invalid_code"
        )

    fun idleToMap(): Map<String, Any?> =
        mapOf("status" to "idle")


    /**
     * Maps a [PairingPollResult] to the contract map, given the cached pending
     * start result and vehicle/account context. Pure.
     */
    fun pollResultToMap(
        pollResult: PairingPollResult,
        pending: PairingStartResult?,
        vehicleId: String
    ): Map<String, Any?> = when (pollResult) {
        is PairingPollResult.Pending -> pendingToMap(pending, vehicleId)
        is PairingPollResult.Approved -> approvedToMap(vehicleId, pollResult.accountId)
        is PairingPollResult.Expired -> expiredToMap()
        is PairingPollResult.Rejected -> rejectedToMap()
        is PairingPollResult.InvalidCode -> invalidCodeToMap()
    }

    fun terminalToMap(terminal: String): Map<String, Any?> = when (terminal) {
        "expired" -> expiredToMap()
        "registered" -> registeredToMap()
        "revoked" -> revokedToMap()
        "rejected" -> rejectedToMap()
        "invalidCode" -> invalidCodeToMap()
        else -> mapOf("status" to terminal, "reason" to terminal)
    }
}
