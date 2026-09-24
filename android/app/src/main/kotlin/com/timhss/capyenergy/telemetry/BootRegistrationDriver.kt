package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.pairing.DevicePairingException
import com.timhss.capyenergy.telemetry.pairing.PairingCoordinator
import kotlinx.coroutines.runBlocking

/**
 * Boot-time pre-claim registration driver (issue #236 P2-T6).
 *
 * Runs once per boot (and on the 15-minute cloud tick as backstop), only for
 * a car that owes it: `unpaired` with no stored token, or a `registered` car
 * whose credential was minted under a vehicle id that has since been retired
 * (B1 re-key — an android_id-bound token can never upload VIN-keyed rows).
 *
 * This is a separate class from [TelemetryRuntime] so the whole decision
 * surface is unit-testable with real time control: when a registration
 * happens, when it is skipped, and the bounded backoff after a failure. The
 * runtime holds one instance and calls [run] from its startup maintenance and
 * its upload tick. All side channels (vehicle id, clock, retry scheduling)
 * are injected so tests drive them without a coroutine clock.
 */
internal class BootRegistrationDriver(
    private val coordinator: PairingCoordinator,
    private val settings: TelemetrySettings,
    private val vehicleIdProvider: () -> String,
    private val nowMillis: () -> Long,
    private val scheduleRetry: (delayMillis: Long) -> Unit,
    private val baseRetryDelayMillis: Long = 5_000L,
    private val maxRetryDelayMillis: Long = 60_000L,
    private val maxRetryStates: Int = 4,
) {
    private var attempt = 0

    /**
     * Runs one registration attempt.
     *
     * Skips silently when no registration is owed (token present and still
     * valid for the current id, pending/approved/revoked status, or the
     * vehicle id not yet minted). A network failure schedules a retry with
     * bounded backoff; a blank-token refusal drops the credential back to
     * `unpaired` instead of spinning. Recording never blocks on this.
     */
    fun run() {
        val vehicleId = vehicleIdProvider().takeIf { it.isNotBlank() && it != "unassigned" }
            ?: return
        if (!coordinator.shouldRegister(vehicleId)) return
        runCatching {
            runBlocking { coordinator.registerAndSave(vehicleId, nowMillis) }
        }
            .onSuccess {
                attempt = 0
                onRegistered(vehicleId)
            }
            .onFailure { error ->
                if (error is DevicePairingException && error.message?.contains("blank car_token") == true) {
                    // Server-side fault; a retry would repeat it blindly. Drop
                    // the credential so the next boot tries honestly instead
                    // of a phantom `registered` that uploads nothing.
                    settings.resetRegistration()
                    onRefused(error)
                    return
                }
                if (attempt < maxRetryStates) {
                    val delay = minOf(baseRetryDelayMillis shl attempt, maxRetryDelayMillis)
                    attempt += 1
                    scheduleRetry(delay)
                } else {
                    onRetriesExhausted(error)
                }
            }
    }

    var onRegistered: (vehicleId: String) -> Unit = {}
    var onRefused: (error: Throwable) -> Unit = {}
    var onRetriesExhausted: (error: Throwable) -> Unit = {}
}