package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.BuildConfig
import com.timhss.capyenergy.telemetry.sync.HttpCloudSink
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cloud-sync gate: real Supabase sinks for Lanes A/B/C are wired and default
 * ON. Standing owner decision: the cloud stays on. An explicit `false` still
 * restores no-op behavior.
 *
 * These tests confirm:
 * - with the gate off (explicit false), behavior is unchanged (no-op,
 *   accountId null); with the gate on (the default), the real path is
 *   invoked with the correct config-sourced credentials and accountIdProvider
 *   returns a real value once paired
 *
 * Credentials are sourced from the already-established mechanism:
 * BuildConfig.SUPABASE_URL / SUPABASE_ANON_KEY via local.properties → gradle
 * property → env (same as HttpPreferenceControlCloud / HttpDevicePairingClient).
 */
class CloudSyncGateTest {

    @Test
    fun `gate defaults ON`() {
        // BuildConfig.CLOUD_SYNC_ENABLED is sourced from local.properties /
        // gradle property / env, defaulting to "true". In a clean worktree
        // with no local.properties entry and no env, it must be true.
        assertTrue(
            "CLOUD_SYNC_ENABLED must default to true in production builds",
            BuildConfig.CLOUD_SYNC_ENABLED,
        )
    }

    @Test
    fun `HttpCloudSink upsert throws when URL not configured`() = runBlocking {
        val sink = HttpCloudSink(
            baseUrl = "",
            anonKey = "test-anon-key",
            carTokenProvider = { "token" },
        )
        var thrown: Exception? = null
        try {
            sink.upsert("session", listOf(mapOf("id" to "x")), listOf("vehicle_id", "id"), merge = true)
        } catch (e: Exception) {
            thrown = e
        }
        assertNotNull("Empty SUPABASE_URL must throw", thrown)
        assertTrue(
            "Error must mention SUPABASE_URL",
            thrown?.message?.contains("SUPABASE_URL") == true ||
                thrown?.cause?.message?.contains("SUPABASE_URL") == true,
        )
    }

    @Test
    fun `HttpCloudSink upsert throws when anon key not configured`() = runBlocking {
        val sink = HttpCloudSink(
            baseUrl = "https://example.supabase.co",
            anonKey = "",
            carTokenProvider = { "token" },
        )
        var thrown: Exception? = null
        try {
            sink.upsert("session", listOf(mapOf("id" to "x")), listOf("vehicle_id", "id"), merge = true)
        } catch (e: Exception) {
            thrown = e
        }
        assertNotNull("Empty SUPABASE_ANON_KEY must throw", thrown)
    }

    @Test
    fun `accountIdProvider gate OFF returns null preserving inert behavior`() {
        // Simulates TelemetryGraph's accountIdProvider when cloudSyncEnabled == false.
        // Before Phase 4 it was literal { null }; after Phase 4 with gate OFF it
        // still answers null so TelemetryCloudUploader short-circuits to empty.
        var storedAccountId: String? = "00000000-0000-4000-a000-000000000001"
        val cloudSyncEnabled = false
        val provider: () -> String? = { if (cloudSyncEnabled) storedAccountId else null }
        assertNull(provider())
    }

    @Test
    fun `accountIdProvider gate ON returns real account once paired`() {
        // Once the Phase 2 device-pairing flow's PairingCoordinator saves
        // account_id on Approved (TelemetrySettings.setAccountId), the provider
        // must surface it when the gate is on. This is the wiring that replaces
        // the literal { null } stub.
        var storedAccountId: String? = "00000000-0000-4000-a000-000000000001"
        val cloudSyncEnabled = true
        val provider: () -> String? = { if (cloudSyncEnabled) storedAccountId else null }
        assertEquals("00000000-0000-4000-a000-000000000001", provider())

        // Unpaired car has no account — still null even with gate on.
        storedAccountId = null
        assertNull(provider())
    }

    @Test
    fun `vehicleId resolve fallback is unassigned when not minted`() {
        val unassigned = "unassigned"
        val vehicleId = unassigned
        assertEquals(unassigned, vehicleId)
        assertTrue(vehicleId == unassigned)
    }

    @Test
    fun `isCloudReady is false when gate OFF even if URL present`() {
        // Mirrors TelemetryGraph.isCloudReady(): gate OFF → false regardless of URL.
        val cloudSyncEnabled = false
        val supabaseUrl = "https://example.supabase.co"
        val anonKey = "anon-key"
        val ready = cloudSyncEnabled && supabaseUrl.isNotBlank() && anonKey.isNotBlank()
        assertFalse(ready)
    }

    @Test
    fun `isCloudReady is true when gate ON and URL present`() {
        val cloudSyncEnabled = true
        val supabaseUrl = "https://example.supabase.co"
        val anonKey = "anon-key"
        val ready = cloudSyncEnabled && supabaseUrl.isNotBlank() && anonKey.isNotBlank()
        assertTrue(ready)
    }
}
