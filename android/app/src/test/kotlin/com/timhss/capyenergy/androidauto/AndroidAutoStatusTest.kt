package com.timhss.capyenergy.androidauto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidAutoStatusTest {

    private fun status(
        available: Boolean = true,
        bound: Boolean = true,
        attached: Boolean = true,
        activityResumed: Boolean = true,
        dartActive: Boolean = true,
        textureId: Long? = 7L,
        bufferWidth: Int = 1920,
        bufferHeight: Int = 1080,
        attachCount: Int = 3,
        lastError: String? = null,
    ) = AndroidAutoStatus(
        available = available,
        bound = bound,
        attached = attached,
        activityResumed = activityResumed,
        dartActive = dartActive,
        textureId = textureId,
        bufferWidth = bufferWidth,
        bufferHeight = bufferHeight,
        attachCount = attachCount,
        lastError = lastError,
    )

    // Assert 1: exactly the 10 documented keys, no more, no less.
    @Test
    fun toMapHasExactlyTheTenDocumentedKeys() {
        val keys = status().toMap().keys
        assertEquals(
            setOf(
                "available",
                "bound",
                "attached",
                "activityResumed",
                "dartActive",
                "textureId",
                "bufferWidth",
                "bufferHeight",
                "attachCount",
                "lastError",
            ),
            keys,
        )
    }

    // Assert 2: textureId null when absent, Long when present.
    @Test
    fun textureIdRoundTrips() {
        assertNull(status(textureId = null).toMap()["textureId"])
        val value = status(textureId = 9L).toMap()["textureId"]
        assertEquals(9L, value as Long)
    }

    // Assert 3: every value is a Boolean, Int, Long or String? — the types the
    // standard message codec carries to Dart unchanged.
    @Test
    fun everyValueIsStandardCodecType() {
        val map = status(lastError = "INVALID_BUFFER_SIZE").toMap()
        for (key in listOf("available", "bound", "attached", "activityResumed", "dartActive")) {
            assertTrue("$key should be a Boolean", map[key] is Boolean)
        }
        for (key in listOf("bufferWidth", "bufferHeight", "attachCount")) {
            assertTrue("$key should be an Int", map[key] is Int)
        }
        assertTrue("textureId should be a Long", map["textureId"] is Long)
        assertTrue("lastError should be a String", map["lastError"] is String)
    }

    @Test
    fun nullabilitiesHold() {
        val map = status(textureId = null).toMap()
        assertNull(map["textureId"])
        assertNull(map["lastError"])
    }

    // Assert 4: lastError is one of the eight documented codes, or null.
    @Test
    fun lastErrorIsDocumentedCodeOrNull() {
        val allowed = setOf(
            null,
            "BIND_FAILED",
            "SERVICE_UNAVAILABLE",
            "BINDING_DIED",
            "NULL_BINDING",
            "ATTACH_FAILED",
            "DETACH_FAILED",
            "REMOTE_EXCEPTION",
            "INVALID_BUFFER_SIZE",
        )
        for (code in allowed) {
            val value = status(lastError = code).toMap()["lastError"]
            assertTrue("$code must survive the round trip", value == code)
        }
        // An unknown value would be a contract violation caught by the Dart
        // generic fallback, but the native side must never send one.
        assertEquals(8, allowed.size - 1)
    }
}
