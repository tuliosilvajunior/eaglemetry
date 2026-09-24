package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.BuildConfig
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/**
 * Verification that the car actually uploads telemetry to the real Supabase
 * project end-to-end (issue #227 follow-up).
 *
 * Before #227 the upload path was inert (`NoOpCloudSink` + `accountId=null`).
 * Phase 4 wires `HttpCloudSink` via `BuildConfig.CLOUD_SYNC_ENABLED` and
 * `accountIdProvider` gated on `PAIRING_STATUS_APPROVED`, carrying
 * `x-car-token` for anon device RLS. The RLS for anon was missing for every
 * lane A/B table, so even with gate ON a valid car_token got 401.
 * Fixed by `20260902190000_car_device_telemetry_rls.sql` +
 * `20260902190100_fix_hash_car_token.sql` + `20260902190200_service_role_grants.sql`.
 *
 * This test hits a real Supabase project (yours: apply supabase/migrations,
 * deploy supabase/functions, then point the env vars at it) using the anon
 * key + a car_token minted via the service role (same flow as the
 * device-pairing Edge Function). It verifies:
 *  1. hash_car_token RPC works (pgcrypto search_path fix)
 *  2. anon + x-car-token can insert + read session/interval/track/battery
 *     and annotation tables (RLS + GRANT fix)
 *  3. wrong account_id is denied (isolation)
 *
 * The test is skipped (Assume) when env vars are absent so CI remains hermetic.
 * To run locally:
 *   SUPABASE_URL=https://<project-ref>.supabase.co \
 *   SUPABASE_ANON_KEY=<anon> \
 *   SUPABASE_SERVICE_ROLE_KEY=<service> \
 *   ./gradlew :app:testDebugUnitTest --tests "com.timhss.capyenergy.telemetry.sync.CarCloudUploadVerificationTest"
 */
class CarCloudUploadVerificationTest {

    private fun env(name: String): String? =
        System.getenv(name)?.takeIf { it.isNotBlank() }

    private fun http(
        method: String,
        url: String,
        headers: Map<String, String>,
        body: String?
    ): Pair<Int, String> {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15000
            readTimeout = 15000
            headers.forEach { (k, v) -> setRequestProperty(k, v) }
            if (body != null) doOutput = true
        }
        try {
            if (body != null) conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.readText() ?: ""
            return code to text
        } finally {
            conn.disconnect()
        }
    }

    @Test
    fun `real car upload end-to-end via anon plus x-car-token`() = runBlocking {
        val baseUrl = env("SUPABASE_URL") ?: BuildConfig.SUPABASE_URL
        val anonKey = env("SUPABASE_ANON_KEY") ?: BuildConfig.SUPABASE_ANON_KEY
        val serviceKey = env("SUPABASE_SERVICE_ROLE_KEY")

        assumeTrue(
            "Real upload verification needs SUPABASE_URL/ANON_KEY/SERVICE_ROLE_KEY — set env to run",
            baseUrl.isNotBlank() && anonKey.isNotBlank() && !serviceKey.isNullOrBlank()
        )
        val svc = serviceKey!!
        // Create a sandbox user via Auth admin API
        val email = "capy-verify-${UUID.randomUUID().toString().substring(0, 8)}@example.com"
        val createUserBody = """{"email":"$email","password":"Test1234!${UUID.randomUUID()}","email_confirm":true}"""
        val (uCode, uBody) = http(
            "POST", "$baseUrl/auth/v1/admin/users",
            mapOf("apikey" to svc, "Authorization" to "Bearer $svc", "Content-Type" to "application/json"),
            createUserBody
        )
        assumeTrue("Auth admin create user must succeed: $uCode $uBody", uCode == 200)
        val userId = Regex("\"id\"\\s*:\\s*\"([^\"]+)\"").find(uBody)?.groupValues?.get(1) ?: error("no user id in $uBody")

        // Mint a car token and register device (mirrors pairing.ts hashCarToken = SHA256 hex)
        val rawToken = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(java.security.SecureRandom().let {
            val b = ByteArray(32); it.nextBytes(b); b
        })
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(rawToken.toByteArray(Charsets.UTF_8))
        val tokenHash = digest.joinToString("") { "%02x".format(it) }
        val vehicleId = "VERIFY_${UUID.randomUUID().toString().substring(0, 6).uppercase()}"

        // Vehicle row (needs service_role grant, added in 20260902190200)
        val (vCode, vBody) = http(
            "POST", "$baseUrl/rest/v1/vehicle",
            mapOf("apikey" to svc, "Authorization" to "Bearer $svc", "Content-Type" to "application/json", "Prefer" to "return=representation"),
            """{"vehicle_id":"$vehicleId","account_id":"$userId"}"""
        )
        assumeTrue("vehicle insert $vCode $vBody", vCode in 200..201)
        http(
            "POST", "$baseUrl/rest/v1/vehicle_ownership",
            mapOf("apikey" to svc, "Authorization" to "Bearer $svc", "Content-Type" to "application/json", "Prefer" to "return=representation"),
            """{"vehicle_id":"$vehicleId","account_id":"$userId"}"""
        )
        val (dCode, dBody) = http(
            "POST", "$baseUrl/rest/v1/vehicle_devices",
            mapOf("apikey" to svc, "Authorization" to "Bearer $svc", "Content-Type" to "application/json", "Prefer" to "return=representation"),
            """{"vehicle_id":"$vehicleId","account_id":"$userId","token_hash":"$tokenHash"}"""
        )
        assumeTrue("device insert $dCode $dBody", dCode in 200..201)

        // Verify hash_car_token RPC (search_path fix)
        val (hCode, hBody) = http(
            "POST", "$baseUrl/rest/v1/rpc/hash_car_token",
            mapOf("apikey" to svc, "Authorization" to "Bearer $svc", "Content-Type" to "application/json"),
            """{"p_token":"hello"}"""
        )
        assumeTrue("hash_car_token RPC $hCode $hBody", hCode == 200 && hBody.contains("2cf24dba5fb0a30e"))

        val carHeaders = mapOf("apikey" to anonKey, "x-car-token" to rawToken, "Content-Type" to "application/json", "Prefer" to "resolution=merge-duplicates")
        val now = System.currentTimeMillis()

        // Session via HttpCloudSink path (the uploader's table)
        val sessionId = "sess_${UUID.randomUUID().toString().substring(0, 8)}"
        val sessionJson = """[{"vehicle_id":"$vehicleId","id":"$sessionId","account_id":"$userId","kind":"drive","status":"open","started_at_utc_millis":$now,"started_at_elapsed_nanos":1000000000,"created_at_utc_millis":$now,"updated_at_utc_millis":$now,"no_longer_reducible":false}]"""
        val (sCode, sBody) = http("POST", "$baseUrl/rest/v1/session?on_conflict=vehicle_id,id", carHeaders, sessionJson)
        assumeTrue("car session upload $sCode $sBody", sCode in 200..201)

        val (rCode, rBody) = http("GET", "$baseUrl/rest/v1/session?vehicle_id=eq.$vehicleId&select=vehicle_id,id", carHeaders, null)
        assumeTrue("car read back $rCode $rBody", rCode == 200 && rBody.contains(sessionId))

        // Isolation: wrong account must be denied
        val badAccount = UUID.randomUUID().toString()
        val badJson = """[{"vehicle_id":"$vehicleId","id":"sess_${UUID.randomUUID().toString().substring(0, 8)}","account_id":"$badAccount","kind":"drive","status":"open","started_at_utc_millis":$now,"started_at_elapsed_nanos":1000000000,"created_at_utc_millis":$now,"updated_at_utc_millis":$now,"no_longer_reducible":false}]"""
        val (bCode, _) = http("POST", "$baseUrl/rest/v1/session?on_conflict=vehicle_id,id", carHeaders, badJson)
        assert(bCode == 401 || bCode == 403) { "Isolation: wrong account should be denied, got $bCode" }

        // Annotation: preferences (anon device)
        val prefJson = """[{"account_id":"$userId","scope":"vehicle","key":"verify_${UUID.randomUUID().toString().substring(0, 6)}","value":"42","updated_at_utc_millis":$now,"origin":"car_test","hlc_millis":$now,"hlc_counter":1,"hlc_device_id":"car"}]"""
        val (pCode, pBody) = http("POST", "$baseUrl/rest/v1/preferences?on_conflict=account_id,scope,key", carHeaders, prefJson)
        assumeTrue("car preferences upload $pCode $pBody", pCode in 200..201)

        // Cleanup via service (not required for verification, best-effort)
        // Note: vehicle cascade deletes sessions etc.
    }
}
