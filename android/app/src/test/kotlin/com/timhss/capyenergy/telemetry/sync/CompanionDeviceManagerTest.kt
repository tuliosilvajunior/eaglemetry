package com.timhss.capyenergy.telemetry.sync

import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class CompanionDeviceManagerTest {
    private lateinit var store: InMemoryCompanionDeviceStore
    private lateinit var manager: CompanionDeviceManager

    @Before
    fun setUp() {
        store = InMemoryCompanionDeviceStore()
        manager = CompanionDeviceManager(store)
    }


    @Test
    fun `validateAuthHeader covers method, pathWithQuery, timestamp and body sha256`() {
        val secret = "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE="
        val device = CompanionDevice(
            deviceId = "device-1",
            deviceName = "Phone",
            pairedAtUtcMillis = 1000L,
            sharedSecret = secret
        )
        manager.registerDevice(device)

        val now = 2000000L
        val bodyBytes = "{\"recordId\":\"session-1\"}".toByteArray(StandardCharsets.UTF_8)
        val validHeader = manager.createAuthHeader(secret, "POST", "/sync/ack", bodyBytes, now)

        assertTrue(manager.validateAuthHeader(validHeader, "POST", "/sync/ack", "device-1", bodyBytes, now))
        
        // Path with query param
        val queryPath = "/sync/pull?stream=tripSessions&limit=50"
        val getHeader = manager.createAuthHeader(secret, "GET", queryPath, null, now)
        assertTrue(manager.validateAuthHeader(getHeader, "GET", queryPath, "device-1", null, now))
        assertFalse(manager.validateAuthHeader(getHeader, "GET", "/sync/pull?stream=chargeSessions", "device-1", null, now))

        // Reject tampered body
        val tamperedBody = "{\"recordId\":\"session-2\"}".toByteArray(StandardCharsets.UTF_8)
        assertFalse(manager.validateAuthHeader(validHeader, "POST", "/sync/ack", "device-1", tamperedBody, now))

        // Reject wrong method
        assertFalse(manager.validateAuthHeader(validHeader, "GET", "/sync/ack", "device-1", bodyBytes, now))
        
        // Reject wrong path
        assertFalse(manager.validateAuthHeader(validHeader, "POST", "/sync/pull", "device-1", bodyBytes, now))

        // Reject wrong device
        assertFalse(manager.validateAuthHeader(validHeader, "POST", "/sync/ack", "unknown-device", bodyBytes, now))

        // Reject timestamp outside tolerance window
        val outsideTolerance = now + CompanionDeviceManager.TOKEN_TOLERANCE_MILLIS + 1000
        assertFalse(manager.validateAuthHeader(validHeader, "POST", "/sync/ack", "device-1", bodyBytes, outsideTolerance))
    }

    @Test
    fun `validateAuthHeader returns false safely when shared secret is corrupt base64`() {
        val device = CompanionDevice(
            deviceId = "corrupt-device",
            deviceName = "Phone",
            pairedAtUtcMillis = 1000L,
            sharedSecret = "not-valid-base64!!!"
        )
        manager.registerDevice(device)

        val token = "Bearer 2000000:some-signature-hex"
        assertFalse(manager.validateAuthHeader(token, "GET", "/sync/pull", "corrupt-device", null, 2000L))
    }

    @Test
    fun `revokeDevice removes device and invalidates auth`() {
        val secret = "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE="
        val device = CompanionDevice("dev-to-revoke", "Phone", 1000L, secret)
        manager.registerDevice(device)
        assertNotNull(manager.findDevice("dev-to-revoke"))

        val token = manager.createAuthHeader(secret, "GET", "/sync/pull", null, 2000L)
        assertTrue(manager.validateAuthHeader(token, "GET", "/sync/pull", "dev-to-revoke", null, 2000L))

        assertTrue(manager.revokeDevice("dev-to-revoke"))
        assertNull(manager.findDevice("dev-to-revoke"))
        assertFalse(manager.validateAuthHeader(token, "GET", "/sync/pull", "dev-to-revoke", null, 2000L))
    }
}
