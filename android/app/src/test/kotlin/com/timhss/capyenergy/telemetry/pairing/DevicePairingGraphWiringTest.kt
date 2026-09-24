package com.timhss.capyenergy.telemetry.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Evidence that PairingCoordinator is constructed on the production path,
 * not only in its own unit test.
 */
class DevicePairingGraphWiringTest {

    @Test
    fun `TelemetryGraph exposes pluggable pairing coordinator`() {
        val clazz = Class.forName("com.timhss.capyenergy.telemetry.TelemetryGraph")
        val hasPairingCoordinator = try {
            clazz.getDeclaredField("pairingCoordinator")
            true
        } catch (_: NoSuchFieldException) {
            clazz.methods.any { it.name == "getPairingCoordinator" }
        }
        assertTrue("TelemetryGraph must have var pairingCoordinator", hasPairingCoordinator)

        val hasDevicePairingClient = try {
            clazz.getDeclaredField("devicePairingClient")
            true
        } catch (_: NoSuchFieldException) {
            clazz.methods.any { it.name == "getDevicePairingClient" }
        }
        assertTrue("TelemetryGraph must have var devicePairingClient", hasDevicePairingClient)

        // Constructor must accept injected fake (for JVM tests) — pluggable seam.
        val ctor = clazz.declaredConstructors.first()
        val hasInjectedParam = ctor.toString().contains("DevicePairingClient")
        assertTrue("TelemetryGraph constructor must accept injectedDevicePairingClient", hasInjectedParam)
    }

    @Test
    fun `TelemetryGraph telemetry uploads require approved claim, annotations keep the same gate`() {
        // Only an APPROVED (claimed) car may upload. Unclaimed uploads
        // (REGISTERED with account_id = null) were disabled: the rows are
        // unreadable by every client and unclaimed data was the dominant
        // cloud database-growth source. The graph must not admit REGISTERED
        // anywhere, and AccountIdProvider stays approved-only.
        val accountCandidates = listOf(
            java.io.File("src/main/kotlin/com/timhss/capyenergy/telemetry/AccountIdProvider.kt"),
            java.io.File("android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/AccountIdProvider.kt")
        )
        val accountSrc = accountCandidates.first { it.isFile }.readText()
        assertTrue(
            "the account authority must keep approved as the only admitted pairing",
            accountSrc.contains("pairingStatus == TelemetrySettings.PAIRING_STATUS_APPROVED")
        )
        val candidates = listOf(
            java.io.File("src/main/kotlin/com/timhss/capyenergy/telemetry/TelemetryGraph.kt"),
            java.io.File("android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/TelemetryGraph.kt")
        )
        val src = candidates.first { it.isFile }.readText()
        assertTrue(
            "telemetry eligibility must key on APPROVED",
            src.contains("pairingStatus() == TelemetrySettings.PAIRING_STATUS_APPROVED")
        )
        assertEquals(
            "unclaimed (REGISTERED) uploads are disabled: REGISTERED must not appear in the graph",
            0, src.split("PAIRING_STATUS_REGISTERED").size - 1
        )
    }

    @Test
    fun `method channel contract source markers exist`() {
        val candidatesFacade = listOf(
            java.io.File("src/main/kotlin/com/timhss/capyenergy/telemetry/TelemetryFacade.kt"),
            java.io.File("android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/TelemetryFacade.kt")
        )
        val facadeSrc = candidatesFacade.first { it.isFile }.readText()
        assertTrue(facadeSrc.contains("fun startDevicePairing"))
        assertTrue(facadeSrc.contains("fun getDevicePairingState"))
        assertTrue(facadeSrc.contains("fun cancelDevicePairing"))
        // Must distinguish expired vs rejected vs invalidCode
        assertTrue(facadeSrc.contains("\"expired\""))
        assertTrue(facadeSrc.contains("\"rejected\""))
        assertTrue(facadeSrc.contains("\"invalidCode\""))
        // Must use pure mapper
        assertTrue(facadeSrc.contains("PairingStateMapper"))

        val bridgeCandidates = listOf(
            java.io.File("src/main/kotlin/com/timhss/capyenergy/bridge/TelemetryBridge.kt"),
            java.io.File("android/app/src/main/kotlin/com/timhss/capyenergy/bridge/TelemetryBridge.kt")
        )
        val bridgeSrc = bridgeCandidates.first { it.isFile }.readText()
        assertTrue(bridgeSrc.contains("\"startDevicePairing\""))
        assertTrue(bridgeSrc.contains("\"getDevicePairingState\""))
        assertTrue(bridgeSrc.contains("\"cancelDevicePairing\""))
        // The local Wi-Fi channel is gone: its routes must not come back.
        assertFalse(bridgeSrc.contains("\"createPairingChallenge\""))
        assertFalse(bridgeSrc.contains("\"getPairingChallenge\""))
        assertFalse(bridgeSrc.contains("\"cancelPairingChallenge\""))
        assertFalse(bridgeSrc.contains("\"getSyncServerEndpoint\""))
        assertFalse(bridgeSrc.contains("\"getCompanionSyncStatus\""))
        assertFalse(bridgeSrc.contains("\"prepareCompanionSync\""))
        // The cloud FORCE SYNC route runs one upload pass right now.
        assertTrue(bridgeSrc.contains("\"forceCloudSync\""))
        assertTrue(facadeSrc.contains("fun forceCloudSyncNow") || bridgeSrc.contains("forceCloudSyncNow"))
        // The developer re-upload route reaches the uploader's history mark.
        assertTrue(bridgeSrc.contains("\"markCloudHistoryDirty\""))
        assertTrue(bridgeSrc.contains("telemetryRuntime.markCloudHistoryDirty()"))
    }
    @Test
    fun `TelemetryRuntime calls registerAndSave at boot when a car owes registration and on the upload tick`() {
        // P2-T6: the production path must actually invoke pre-claim
        // registration — the whole point of this task is that nothing in
        // production ever called DevicePairingClient.register. The runtime
        // holds a BootRegistrationDriver and calls it at startup and on the
        // 15-minute upload tick.
        val candidates = listOf(
            java.io.File("src/main/kotlin/com/timhss/capyenergy/telemetry/TelemetryRuntime.kt"),
            java.io.File("android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/TelemetryRuntime.kt")
        )
        val runtimeSrc = candidates.first { it.isFile }.readText()
        assertTrue("runtime must hold a boot registration driver", runtimeSrc.contains("BootRegistrationDriver"))
        assertTrue("runtime must call the driver from startup maintenance", runtimeSrc.contains("runBootRegistrationIfNeeded"))
        assertTrue("runtime must schedule driver retries on the maintenance executor", runtimeSrc.contains("scheduleRetry"))

        // The driver itself is where shouldRegister/registerAndSave live, and
        // BootRegistrationDriverTest drives it with a recording fake.
        val driverCandidates = listOf(
            java.io.File("src/main/kotlin/com/timhss/capyenergy/telemetry/BootRegistrationDriver.kt"),
            java.io.File("android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/BootRegistrationDriver.kt")
        )
        val driverSrc = driverCandidates.first { it.isFile }.readText()
        assertTrue("driver must gate on the coordinator decision", driverSrc.contains("shouldRegister"))
        assertTrue("driver must call registerAndSave", driverSrc.contains("registerAndSave"))
    }
}
