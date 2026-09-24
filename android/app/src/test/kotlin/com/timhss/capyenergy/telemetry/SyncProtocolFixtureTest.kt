package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.sync.CompanionDevice
import com.timhss.capyenergy.telemetry.sync.CompanionDeviceManager
import com.timhss.capyenergy.telemetry.sync.InMemoryCompanionDeviceStore
import com.timhss.capyenergy.telemetry.sync.SyncCursorRepository
import com.timhss.capyenergy.telemetry.sync.SyncStreamType
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Validates the wire-level HMAC request auth token format, signature rules,
 * and HLC ordering/drift bounds against the shared fixture `testdata/sync_protocol_cases.json`.
 */
class SyncProtocolFixtureTest {
    private val fixtureJson: JSONObject = fixture()
    private val cases: JSONArray = fixtureJson.getJSONArray("cases")

    @Test
    fun `the fixture carries all expected protocol test cases`() {
        assertEquals(3, cases.length())
    }

    @Test
    fun `every protocol fixture case passes Kotlin signature and token generation`() {
        val store = InMemoryCompanionDeviceStore()
        val manager = CompanionDeviceManager(store)

        for (i in 0 until cases.length()) {
            val testCase = cases.getJSONObject(i)
            val name = testCase.getString("name")
            val secret = testCase.getString("sharedSecret")
            val method = testCase.getString("method")
            val pathWithQuery = testCase.getString("pathWithQuery")
            val timestampMillis = testCase.getLong("timestampMillis")
            val body = testCase.getString("body")
            val expectedBodySha256 = testCase.getString("expectedBodySha256")
            val expectedToken = testCase.getString("expectedToken")

            val bodyBytes = body.toByteArray(StandardCharsets.UTF_8)
            val actualBodySha256 = MessageDigest.getInstance("SHA-256")
                .digest(bodyBytes)
                .joinToString("") { "%02x".format(it) }

            assertEquals("[$name] Body SHA256 mismatch", expectedBodySha256, actualBodySha256)

            val generatedToken = manager.createAuthHeader(
                sharedSecret = secret,
                method = method,
                pathWithQuery = pathWithQuery,
                bodyBytes = bodyBytes,
                timestampMillis = timestampMillis
            )
            assertEquals("[$name] Generated token mismatch", expectedToken, generatedToken)

            val deviceId = "fixture-device"
            manager.registerDevice(
                CompanionDevice(
                    deviceId = deviceId,
                    deviceName = "Fixture Device",
                    pairedAtUtcMillis = timestampMillis - 1000,
                    sharedSecret = secret
                )
            )

            val isValid = manager.validateAuthHeader(
                authHeader = expectedToken,
                method = method,
                pathWithQuery = pathWithQuery,
                deviceId = deviceId,
                bodyBytes = bodyBytes,
                nowMillis = timestampMillis
            )
            assertTrue("[$name] Token validation must succeed", isValid)
        }
    }

    @Test
    fun `streamNames match the Kotlin SyncStreamType spelling`() {
        val names = fixtureJson.getJSONArray("streamNames")
        val fixtureNames = (0 until names.length()).map { names.getString(it) }
        assertEquals(fixtureNames, SyncStreamType.entries.map { it.wireName })
    }

    @Test
    fun `envelopeVersion and envelopeKeys match Kotlin SyncBatch definition`() {
        val expectedVersion = fixtureJson.getInt("envelopeVersion")
        assertEquals(expectedVersion, com.timhss.capyenergy.telemetry.sync.SyncBatchPacker.PROTOCOL_VERSION)

        val expectedKeysJson = fixtureJson.getJSONArray("envelopeKeys")
        val expectedKeys = (0 until expectedKeysJson.length()).map { expectedKeysJson.getString(it) }

        val dummyBatch = com.timhss.capyenergy.telemetry.sync.SyncBatch(
            protocolVersion = 1,
            streamType = "tripSessions",
            items = emptyList(),
            nextCursor = "c1",
            hasMore = false,
            generatedAtUtcMillis = 1700000000000L,
            remaining = 0L
        )
        assertEquals(expectedKeys, dummyBatch.toMap().keys.toList())
    }

    @Test
    fun `hlcMaxDriftMillis matches Kotlin MAX_DRIFT_MILLIS`() {
        val maxDrift = fixtureJson.getLong("hlcMaxDriftMillis")
        assertEquals(maxDrift, SyncCursorRepository.MAX_DRIFT_MILLIS)
    }

    @Test
    fun `hlcOrderCases match Kotlin compareHlc`() {
        val hlcOrderCases = fixtureJson.getJSONArray("hlcOrderCases")
        for (i in 0 until hlcOrderCases.length()) {
            val c = hlcOrderCases.getJSONObject(i)
            val a = c.getJSONObject("a")
            val b = c.getJSONObject("b")
            val expectedSign = c.getInt("expectedSign")

            val cmp = SyncCursorRepository.compareHlc(
                a.getLong("millis"), a.getInt("counter"), a.getString("deviceId"),
                b.getLong("millis"), b.getInt("counter"), b.getString("deviceId")
            )
            val actualSign = if (cmp == 0) 0 else if (cmp > 0) 1 else -1
            assertEquals("HLC order case #$i failed", expectedSign, actualSign)
        }
    }

    private fun fixture(): JSONObject {
        val root = requireNotNull(System.getProperty("geely.testdata")) {
            "geely.testdata is unset; see the Test task in android/app/build.gradle.kts"
        }
        val file = File(root, FIXTURE_NAME)
        require(file.isFile) { "The shared fixture is missing at ${file.absolutePath}" }
        return JSONObject(file.readText())
    }

    private companion object {
        const val FIXTURE_NAME = "sync_protocol_cases.json"
    }
}
