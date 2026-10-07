package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.control.PreferenceControlCloudException
import com.timhss.capyenergy.telemetry.sync.AnnotationCloudUploadException
import com.timhss.capyenergy.telemetry.sync.CloudSink
import com.timhss.capyenergy.telemetry.sync.HttpCloudSinkException
import com.timhss.capyenergy.telemetry.sync.TelemetryCloudUploadException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class TelemetryRuntimeRevocationTest {

    private lateinit var ctx: FakeSettingsContext
    private lateinit var settings: TelemetrySettings

    @Before
    fun setUp() {
        ctx = FakeSettingsContext()
        settings = TelemetrySettings(ctx)
    }

    private fun detectorWith(
        sink: CloudSink? = null,
        vehicleId: String = "vin-123"
    ): Pair<RevocationDetector, FakeCloudSink> {
        val fakeSink = (sink as? FakeCloudSink) ?: FakeCloudSink()
        settings.setVehicleId(vehicleId)
        val detector = RevocationDetector(
            settings = settings,
            vehicleIdProvider = { vehicleId },
            cloudSinkProvider = { fakeSink },
            nowMillis = { 1750000000000L }
        )
        return detector to fakeSink
    }

    private class FakeCloudSink : CloudSink {
        var failure: Exception? = null
        val upsertCalls = mutableListOf<Triple<String, List<Map<String, Any?>>, List<String>>>()

        override suspend fun upsert(
            table: String,
            rows: List<Map<String, Any?>>,
            conflictColumns: List<String>,
            merge: Boolean
        ) {
            failure?.let { throw it }
            upsertCalls.add(Triple(table, rows, conflictColumns))
        }

        override suspend fun delete(
            table: String,
            vehicleId: String,
            keys: List<Triple<String, String, Long>>
        ) {}
    }

    @Test
    fun `active readiness propagates authentication failure when requested`() = runBlocking {
        val (detector, sink) = detectorWith()
        settings.setAccountId("account-1")
        val error = TelemetryCloudUploadException("phone_cutover_readiness", HttpCloudSinkException(401, "Invalid API key"), false)
        sink.failure = error
        // Revocation cleanup remains best effort.
        detector.updateCutoverReadiness(active = false)
        try {
            detector.updateCutoverReadiness(active = true, propagateFailure = true)
            org.junit.Assert.fail("Expected authentication failure")
        } catch (actual: TelemetryCloudUploadException) {
            org.junit.Assert.assertSame(error, actual)
        }
    }

    @Test
    fun `isRlsDenial returns true for 403 and 401 with RLS denial bodies`() {
        val (detector, _) = detectorWith()

        val rlsException403 = TelemetryCloudUploadException(
            table = "session",
            cause = HttpCloudSinkException(403, "POST /rest/v1/session failed: HTTP 403: violates row-level security policy for table session"),
            retryable = false
        )
        assertTrue(detector.isRlsDenial(rlsException403))

        val rlsException401 = AnnotationCloudUploadException(
            table = "insight_places",
            cause = HttpCloudSinkException(401, "POST /rest/v1/insight_places failed: HTTP 401: permission denied for table insight_places"),
            retryable = false
        )
        assertTrue(detector.isRlsDenial(rlsException401))

        val code42501 = PreferenceControlCloudException(
            cause = HttpCloudSinkException(403, "POST /rest/v1/preference_reported failed: HTTP 403: {\"code\":\"42501\",\"message\":\"permission denied\"}"),
            retryable = false
        )
        assertTrue(detector.isRlsDenial(code42501))
    }

    @Test
    fun `isRlsDenial returns false for deployment gap 403 without RLS text`() {
        val (detector, _) = detectorWith()

        // Deployment gap: Cloudflare or gateway returns 403 HTML/text without Postgres RLS denial text
        val gateway403 = TelemetryCloudUploadException(
            table = "session",
            cause = HttpCloudSinkException(403, "POST /rest/v1/session failed: HTTP 403: Forbidden - Access Denied by WAF"),
            retryable = false
        )
        assertFalse(detector.isRlsDenial(gateway403))
    }

    @Test
    fun `isRlsDenial returns false for non-401 non-403 errors even if message contains keywords`() {
        val (detector, _) = detectorWith()

        val err500 = TelemetryCloudUploadException(
            table = "session",
            cause = HttpCloudSinkException(500, "POST /rest/v1/session failed: HTTP 500: internal error with row-level security"),
            retryable = true
        )
        assertFalse(detector.isRlsDenial(err500))
    }

    @Test
    fun `RLS denial with token held flips pairing status to revoked`() {
        val (detector, fakeSink) = detectorWith()

        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_APPROVED)
        settings.setCarToken("tok-active")
        settings.setAccountId("00000000-0000-0000-0000-000000000001")

        val rlsException = TelemetryCloudUploadException(
            table = "session",
            cause = HttpCloudSinkException(403, "HTTP 403: violates row-level security policy"),
            retryable = false
        )

        detector.handlePermanentUploadFailure(rlsException)

        assertEquals(TelemetrySettings.PAIRING_STATUS_REVOKED, settings.pairingStatus())
        assertEquals("tok-active", settings.carToken())
        assertEquals("00000000-0000-0000-0000-000000000001", settings.accountId())

        // Also cleared cutover readiness on revoke
        val cutoverWrites = fakeSink.upsertCalls.filter { it.first == "phone_cutover_readiness" }
        assertEquals(1, cutoverWrites.size)
        val row = cutoverWrites.first().second.first()
        assertEquals(false, row["car_direct_upload_active"])
    }

    @Test
    fun `deployment gap 403 does not flip pairing status to revoked`() {
        val (detector, fakeSink) = detectorWith()

        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_APPROVED)
        settings.setCarToken("tok-active")
        settings.setAccountId("00000000-0000-0000-0000-000000000001")

        val deploymentGap403 = TelemetryCloudUploadException(
            table = "session",
            cause = HttpCloudSinkException(403, "HTTP 403: Forbidden - CDN error"),
            retryable = false
        )

        detector.handlePermanentUploadFailure(deploymentGap403)

        assertEquals(TelemetrySettings.PAIRING_STATUS_APPROVED, settings.pairingStatus())
        assertTrue(fakeSink.upsertCalls.isEmpty())
    }

    @Test
    fun `RLS denial without token held does not mark revoked`() {
        val (detector, fakeSink) = detectorWith()

        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_UNPAIRED)
        settings.setCarToken(null)

        val rlsException = TelemetryCloudUploadException(
            table = "session",
            cause = HttpCloudSinkException(403, "HTTP 403: violates row-level security policy"),
            retryable = false
        )

        detector.handlePermanentUploadFailure(rlsException)

        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
        assertTrue(fakeSink.upsertCalls.isEmpty())
    }

    @Test
    fun `updateCutoverReadiness sets flag when direct upload active`() = runBlocking {
        val (detector, fakeSink) = detectorWith(vehicleId = "vin-cutover")

        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_APPROVED)
        settings.setAccountId("00000000-0000-0000-0000-000000000001")

        detector.updateCutoverReadiness(active = true)

        val cutoverWrites = fakeSink.upsertCalls.filter { it.first == "phone_cutover_readiness" }
        assertEquals(1, cutoverWrites.size)
        val row = cutoverWrites.first().second.first()
        assertEquals("vin-cutover", row["vehicle_id"])
        assertEquals("00000000-0000-0000-0000-000000000001", row["account_id"])
        assertEquals(true, row["car_direct_upload_active"])
    }
}
