package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.control.PreferenceControlCloudException
import com.timhss.capyenergy.telemetry.sync.AnnotationCloudUploadException
import com.timhss.capyenergy.telemetry.sync.HttpCloudSinkException
import com.timhss.capyenergy.telemetry.sync.TelemetryCloudUploadException
import org.junit.Assert.*
import org.junit.Test

class CloudUploadPassTest {
    @Test
    fun `readiness authentication failure also fails the result`() {
        for (status in listOf(401, 403, 503)) {
            val pass = runCloudUploadPass({ 0 }, { 0 }, {}, {}, {
                throw TelemetryCloudUploadException("phone_cutover_readiness", HttpCloudSinkException(status, "HTTP $status"), status == 503)
            })
            assertTrue(pass.failed)
            assertEquals(status == 503, pass.retrySoon)
            assertEquals(true, pass.forceSyncResult()["failed"])
        }
    }

    @Test
    fun `401 and 403 fail each lane without requesting an immediate retry`() {
        for (status in listOf(401, 403)) {
            for (lane in 0..2) {
                val cause = HttpCloudSinkException(status, "HTTP $status")
                val error = when (lane) {
                    0 -> TelemetryCloudUploadException("session", cause, false)
                    1 -> AnnotationCloudUploadException("preferences", cause, false)
                    else -> PreferenceControlCloudException(cause, false)
                }
                var handled = 0
                var ready = false
                val pass = runCloudUploadPass(
                    uploadTelemetry = { if (lane == 0) throw error else 3 },
                    uploadAnnotations = { if (lane == 1) throw error else 2 },
                    syncPreferences = { if (lane == 2) throw error },
                    handlePermanentUploadFailure = { assertSame(error, it); handled++ },
                    updateReadiness = { ready = true },
                )
                assertTrue(pass.failed)
                assertFalse(pass.retrySoon)
                assertEquals(true, pass.forceSyncResult()["failed"])
                assertEquals(if (lane == 0) 2 else if (lane == 1) 3 else 5, pass.forceSyncResult()["movedRows"])
                assertEquals(1, handled)
                assertFalse(ready)
            }
        }
    }

    @Test
    fun `permanent failure with zero rows is not an empty success`() {
        val pass = runCloudUploadPass(
            { throw TelemetryCloudUploadException("session", HttpCloudSinkException(401, "Invalid API key"), false) },
            { 0 }, {}, {}, {},
        )
        assertEquals(0, pass.forceSyncResult()["movedRows"])
        assertEquals(true, pass.forceSyncResult()["failed"])
        assertFalse(pass.retrySoon)
    }

    @Test
    fun `transient and unexpected failures remain failures after partial success`() {
        for (error in listOf(
            TelemetryCloudUploadException("session", HttpCloudSinkException(503, "Unavailable"), true),
            IllegalStateException("offline"),
        )) {
            val pass = runCloudUploadPass({ throw error }, { 4 }, {}, { fail("Permanent handler called") }, { fail("Readiness updated") })
            assertTrue(pass.failed)
            assertTrue(pass.retrySoon)
            assertEquals(4, pass.forceSyncResult()["movedRows"])
        }
    }

    @Test
    fun `successful empty and nonempty passes update readiness`() {
        for (rows in listOf(0, 5)) {
            var ready = false
            val pass = runCloudUploadPass({ rows }, { 0 }, {}, {}, { ready = true })
            assertFalse(pass.failed)
            assertFalse(pass.retrySoon)
            assertEquals(false, pass.forceSyncResult()["failed"])
            assertEquals(rows, pass.forceSyncResult()["movedRows"])
            assertTrue(ready)
        }
    }
}
