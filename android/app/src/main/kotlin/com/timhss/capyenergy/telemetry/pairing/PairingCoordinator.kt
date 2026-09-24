package com.timhss.capyenergy.telemetry.pairing

import com.timhss.capyenergy.telemetry.TelemetrySettings
import kotlinx.coroutines.delay

/**
 * Small state-machine driver for the device pairing flow.
 *
 * Mirrors the `CloudSink` pluggability: the network is behind [DevicePairingClient]
 * and the coordinator owns only the flow, the in-memory `device_code`, and the
 * persistence via [TelemetrySettings].
 *
 * `device_code` is never persisted — it is a polling secret, not the
 * pairing state. Only the terminal result (`car_token`, `account_id`,
 * `pairing_status`) is written to [TelemetrySettings].
 *
 * Polling runs every [pollIntervalMillis] until `Approved`, `Expired`,
 * `InvalidCode`, or caller-provided cancellation. On `Approved` the
 * credential is saved and polling stops. On terminal failure or cancel
 * the in-memory code is cleared and no credential is saved.
 *
 * Pre-claim registration (issue #236 Phase 2) sits before the pairing flow:
 * [shouldRegister] / [registerAndSave] give an unpaired car its own token at
 * boot without touching the start/poll/claim lifecycle.
 */
class PairingCoordinator(
    private val client: DevicePairingClient,
    private val settings: TelemetrySettings,
    private val pollIntervalMillis: Long = 5_000L,
    private val sleeper: suspend (Long) -> Unit = { delay(it) },
) {
    /**
     * Hook fired once per `Approved` poll result, after the credential is
     * persisted and the in-memory code is cleared.
     *
     * `accountChanged` is true when the approved `account_id` differs from
     * the previously stored one (null on first pairing) — the caller's cue
     * to re-mark history dirty so it re-syncs under the new account. Firing
     * only here (not on restart, not on re-pairing to the same account)
     * keeps the backfill scoped to "pairing just happened".
     *
     * Runs on the poller's thread: keep it to scheduling background work.
     * A throwing hook does not roll back the saved credential.
     */
    var onApprovedHook: ((approved: PairingPollResult.Approved, accountChanged: Boolean) -> Unit)? = null

    /**
     * In-memory polling secret. Never written to [TelemetrySettings].
     */
    @Volatile
    var currentDeviceCode: String? = null
        private set

    @Volatile
    private var cancelled = false

    /**
     * Begins a pairing session: calls `start`, stores the `device_code`
     * in memory, and marks the pairing status as `pending`.
     *
     * @return the human-readable `user_code` and metadata to show on screen.
     */
    suspend fun start(vehicleId: String): PairingStartResult {
        cancelled = false
        val result = client.start(vehicleId)
        currentDeviceCode = result.deviceCode
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_PENDING)
        return result
    }

    /**
     * Single poll iteration against the stored [currentDeviceCode].
     *
     * Handles persistence on terminal results:
     * - [PairingPollResult.Approved] saves `car_token`/`account_id`/`status`
     *   and clears the in-memory code.
     * - [PairingPollResult.Expired] / [PairingPollResult.Rejected] /
     *   [PairingPollResult.InvalidCode] clears the in-memory code and resets
     *   to `unpaired` via `clearPairing()` (removes stale `car_token`/`account_id`
     *   from a previous approved session if this was a re-pairing attempt).
     *
     * @return the poll result.
     * @throws IllegalStateException if no pairing has been started.
     */
    suspend fun pollOnce(): PairingPollResult {
        val code = currentDeviceCode
            ?: throw IllegalStateException("No pairing in progress (call start() first)")
        val result = client.poll(code)
        when (result) {
            is PairingPollResult.Approved -> {
                val previousAccountId = settings.accountId()
                settings.setCarToken(result.carToken)
                settings.setAccountId(result.accountId)
                settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_APPROVED)
                currentDeviceCode = null
                runCatching {
                    onApprovedHook?.invoke(result, previousAccountId != result.accountId)
                }
            }
            is PairingPollResult.Expired,
            is PairingPollResult.Rejected,
            is PairingPollResult.InvalidCode -> {
                currentDeviceCode = null
                // Only reset if we were pending; preserve approved if somehow
                // already approved (defensive). When resetting from pending,
                // clear the stale credential so uploaders do not keep sending
                // under the previous account while the screen shows expired/
                // rejected/unpaired (re-pairing case).
                if (settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_PENDING) {
                    settings.clearPairing()
                }
            }
            is PairingPollResult.Pending -> {
                // Stay pending, keep code.
            }
        }
        return result
    }

    /**
     * Polls repeatedly until a terminal result or cancellation.
     *
     * @param isCancelled caller-provided cancel check, evaluated before each poll.
     * @return the terminal result, or `null` if cancelled before a terminal result.
     * @throws IllegalStateException if no pairing has been started.
     */
    suspend fun pollUntilDone(isCancelled: () -> Boolean = { cancelled }): PairingPollResult? {
        if (currentDeviceCode == null) {
            throw IllegalStateException("No pairing in progress (call start() first)")
        }
        while (true) {
            if (isCancelled()) {
                currentDeviceCode = null
                return null
            }
            val result = pollOnce()
            when (result) {
                is PairingPollResult.Pending -> {
                    if (isCancelled()) {
                        currentDeviceCode = null
                        return null
                    }
                    if (pollIntervalMillis > 0) {
                        sleeper(pollIntervalMillis)
                    } else {
                        // Yield to allow cancellation check without busy loop in tests with 0 interval;
                        // still allow multiple pending polls without delay.
                        // No sleep when interval is 0.
                    }
                    // Continue, but re-check cancellation at loop top.
                    // If the caller set isCancelled between polls, we exit.
                    continue
                }
                is PairingPollResult.Approved,
                is PairingPollResult.Expired,
                is PairingPollResult.Rejected,
                is PairingPollResult.InvalidCode -> return result
            }
        }
    }
    /**
     * Cancels an in-progress pairing flow.
     *
     * Clears the in-memory `device_code` and resets to `unpaired` via
     * `clearPairing()` if currently `pending` (also removes a stale
     * `car_token`/`account_id` from a previous approved session when cancelling
     * a re-pairing attempt). If already `approved`, the approved credential
     * is preserved — cancellation does not revoke it.
     */
    fun cancel() {
        cancelled = true
        currentDeviceCode = null
        if (settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_PENDING) {
            settings.clearPairing()
        }
    }

    /**
     * Whether a boot-time registration attempt is owed.
     *
     * Called at startup, before any network work. A car registers (or
     * re-registers) when it is `unpaired` with no stored token — and, for
     * issue #236 B1 recovery, when it holds a token minted under a vehicle
     * id that has since been retired (a `registered`-status car whose
     * [TelemetrySettings.registeredVehicleId] no longer matches the current
     * id). The token is bound to the vehicle id it was minted under; an
     * android_id-minted token can never upload VIN-keyed rows, and re-running
     * registration under the VIN is the only self-healing move.
     *
     * An `approved` car is untouched, a `pending` car is mid-claim and must
     * not be disturbed, and a `registered` car whose registration still
     * matches the current id is left alone — no credential churn per boot.
     *
     * A token that is present but blank is impossible through
     * [TelemetrySettings.carToken] (it answers null), but is answered false
     * anyway: a boot must never re-register over a credential it can read.
     */
    fun shouldRegister(currentVehicleId: String): Boolean = when (settings.pairingStatus()) {
        TelemetrySettings.PAIRING_STATUS_UNPAIRED -> settings.carToken() == null
        TelemetrySettings.PAIRING_STATUS_REGISTERED ->
            currentVehicleId.isNotBlank() &&
                currentVehicleId != "unassigned" &&
                settings.registeredVehicleId() != currentVehicleId
        TelemetrySettings.PAIRING_STATUS_PENDING,
        TelemetrySettings.PAIRING_STATUS_APPROVED,
        TelemetrySettings.PAIRING_STATUS_REVOKED -> false
        else -> false
    }

    /**
     * Pre-claim device registration (issue #236 Phase 2): calls the
     * `/register` endpoint and persists the returned car token.
     *
     * Registration gives the car an identity, not an owner: `account_id`
     * stays null (and any stale value is cleared) so a registered-but-unclaimed
     * car uploads with `account_id = null` and Phase 3 adopts those rows at
     * claim time. The token is also bound to the [vehicleId] it was minted
     * under, so a later identity upgrade can detect and re-key it (B1).
     *
     * The blank-token guard: a blank/missing/malformed token coming back from
     * the server is refused — nothing is persisted and the exception carries
     * the raw response so the failure stays visible in logs instead of leaving
     * the car believing it is registered while every upload is refused.
     *
     * @return the registered token.
     * @throws DevicePairingException transport/malformed response; the caller
     *   decides retry.
     */
    suspend fun registerAndSave(
        vehicleId: String,
        clock: () -> Long = System::currentTimeMillis
    ): String {
        val result = client.register(vehicleId)
        val token = result.carToken.trim()
        if (token.isBlank()) {
            throw DevicePairingException(
                "register returned a blank car_token; refusing to persist it"
            )
        }
        settings.register(token = token, vehicleId = vehicleId, atUtcMillis = clock())
        return token
    }

    /**
     * Resets cancellation flag and clears in-memory code without touching
     * persisted state. For tests that reuse the coordinator.
     */
    fun resetForTest() {
        cancelled = false
        currentDeviceCode = null
    }
}