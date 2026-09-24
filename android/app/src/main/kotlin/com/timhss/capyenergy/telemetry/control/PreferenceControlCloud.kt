package com.timhss.capyenergy.telemetry.control

import com.timhss.capyenergy.BuildConfig
import com.timhss.capyenergy.telemetry.sync.OkHttpProvider
import java.net.URLEncoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

/**
 * Lane C (issue #227) — the control plane, seen from the car.
 *
 * Two tables, one writer each:
 *   `preference_desired`  — what the phone wants   (written by the phone)
 *   `preference_reported` — what the car actually did (written by the car)
 *
 * The car never auto-applies a desire and never merges; it only reads what
 * the phone wants and reports what it decided. This package is the car-side
 * read/write path to those tables (Step 2 of Phase 3; Step 3 wires the
 * phone. The local mDNS proposal channel stays as the fallback through
 * Phases 1-3, so this cloud path is additive, never a replacement).
 *
 * The seam mirrors the `CloudSink` split in `telemetry/sync`: one interface,
 * a real JDK-HTTP implementation and a fake for tests. It is richer than
 * `CloudSink` because Lane C also reads, and because every call must carry
 * the car's device-token identity header (`x-car-token`), which the generic
 * sink does not.
 */

/** A row the phone wrote in `preference_desired` — what it wants. */
data class PreferenceDesiredRow(
    val accountId: String,
    val vehicleId: String,
    val key: String,
    val value: String?,
    val proposedAtUtcMillis: Long,
    val origin: String,
)

/** A row the car wrote in `preference_reported` — what it did. */
data class PreferenceReportedRow(
    val vehicleId: String,
    val accountId: String,
    val key: String,
    val value: String?,
    val status: String,
    val decidedAtUtcMillis: Long,
    val reportedAtUtcMillis: Long,
) {
    companion object {
        const val STATUS_ACCEPTED = "accepted"
        const val STATUS_REFUSED = "refused"
    }
}

/**
 * Pluggable network seam for Lane C.
 *
 * Every call is scoped server-side by the `x-car-token` header; the
 * implementer attaches it. Unit tests drive a fake so nothing here ever
 * touches the network in a JVM test.
 */
interface PreferenceControlCloud {
    /** Whether this build can reach the control plane at all. */
    val isConfigured: Boolean

    /** The desires the phone wrote for this vehicle (vehicle-scoped read). */
    suspend fun desiredForVehicle(vehicleId: String): List<PreferenceDesiredRow>

    /** The reports the car already wrote for this vehicle (vehicle-scoped read). */
    suspend fun reportedForVehicle(vehicleId: String): List<PreferenceReportedRow>

    /**
     * Writes decision rows into `preference_reported`.
     *
     * Idempotent per decision: the conflict key is
     * `(vehicle_id, key, decided_at_utc_millis)` and a row already present is
     * left as-is. The table has exactly one writer, so there is nothing to
     * merge with — the task's "plain upsert, not a merge".
     */
    suspend fun report(rows: List<PreferenceReportedRow>)
}

/**
 * Thrown when the control plane cannot be reached or refuses the request.
 *
 * [retryable] is true for network and provider faults a later run may
 * recover from; false for permanent faults (auth, schema, constraints)
 * that a retry will repeat. Mirrors the uploader exceptions in
 * `telemetry/sync`.
 */
class PreferenceControlCloudException(
    cause: Throwable,
    val retryable: Boolean = true,
) : Exception("Preference control cloud request failed: ${cause.message}", cause) {
    companion object {
        fun isRetryable(error: Throwable): Boolean {
            var cur: Throwable? = error
            while (cur != null) {
                val msg = (cur.message ?: "").lowercase()
                if (msg.contains("401") || msg.contains("403")) return false
                if (msg.contains("409") || msg.contains("422")) return false
                if (msg.contains("constraint") || msg.contains("violates")) return false
                if (msg.contains("unique constraint") || msg.contains("foreign key")) return false
                cur = cur.cause
            }
            var c: Throwable? = error
            while (c != null) {
                val name = c.javaClass.simpleName.lowercase()
                if (name.contains("timeout") || name.contains("interrupted")) return true
                c = c.cause
            }
            return true
        }
    }
}

/**
 * Real implementation over [OkHttpClient]. It shares the one connection pool
 * in [OkHttpProvider] with the telemetry and annotation uploads
 * ([com.timhss.capyenergy.telemetry.sync.HttpCloudSink]).
 *
 * Transport contract from Step 1a, sent on every request as an
 * authenticated device:
 *
 * ```
 * apikey: <supabase anon key>      # public; required by Supabase on POST
 * x-car-token: <raw car_token>     # the raw token issued at pairing
 * ```
 *
 * Without a user JWT the request runs as PostgREST's `anon` role, and RLS
 * scopes reads and writes to the vehicle the token resolves to (Step 1b's
 * `preference_desired_device_reads` / `preference_reported_device_*`).
 *
 * [baseUrl] defaults to the build-configured REST endpoint
 * ([BuildConfig.SUPABASE_URL], e.g. `https://<project-ref>.supabase.co`),
 * empty when no Supabase project is wired. The car_token comes from
 * [carTokenProvider] — the credential [com.timhss.capyenergy.telemetry.pairing.PairingCoordinator]
 * saved after an approved pairing; absent on unpaired cars.
 */
class HttpPreferenceControlCloud(
    private val baseUrl: String = BuildConfig.SUPABASE_URL,
    private val anonKey: String = BuildConfig.SUPABASE_ANON_KEY,
    private val carTokenProvider: () -> String? = { null },
    private val client: OkHttpClient = OkHttpProvider.client,
) : PreferenceControlCloud {

    override val isConfigured: Boolean
        get() = baseUrl.isNotBlank() && anonKey.isNotBlank() && !carTokenProvider().isNullOrBlank()

    override suspend fun desiredForVehicle(vehicleId: String): List<PreferenceDesiredRow> = withContext(Dispatchers.IO) {
        val url = restUrl(
            "preference_desired",
            "select=account_id,vehicle_id,key,value,proposed_at_utc_millis,origin" +
                "&vehicle_id=eq.${enc(vehicleId)}"
        )
        val body = request("GET", url, null)
        val results = parseArray(body)
        results.map { json ->
            PreferenceDesiredRow(
                accountId = json.optString("account_id"),
                vehicleId = json.optString("vehicle_id"),
                key = json.optString("key"),
                value = if (json.isNull("value")) null else json.optString("value"),
                proposedAtUtcMillis = json.optLong("proposed_at_utc_millis"),
                origin = json.optString("origin"),
            )
        }
    }

    override suspend fun reportedForVehicle(vehicleId: String): List<PreferenceReportedRow> = withContext(Dispatchers.IO) {
        val url = restUrl(
            "preference_reported",
            "select=vehicle_id,account_id,key,value,status,decided_at_utc_millis,reported_at_utc_millis" +
                "&vehicle_id=eq.${enc(vehicleId)}"
        )
        val body = request("GET", url, null)
        val results = parseArray(body)
        results.map { json ->
            PreferenceReportedRow(
                vehicleId = json.optString("vehicle_id"),
                accountId = json.optString("account_id"),
                key = json.optString("key"),
                value = if (json.isNull("value")) null else json.optString("value"),
                status = json.optString("status"),
                decidedAtUtcMillis = json.optLong("decided_at_utc_millis"),
                reportedAtUtcMillis = json.optLong("reported_at_utc_millis"),
            )
        }
    }

    override suspend fun report(rows: List<PreferenceReportedRow>) {
        if (rows.isEmpty()) return
        withContext(Dispatchers.IO) {
            val url = restUrl(
                "preference_reported",
                "on_conflict=vehicle_id,key,decided_at_utc_millis"
            )
            val payload = JSONArray()
            rows.forEach { row ->
                val item = JSONObject()
                item.put("vehicle_id", row.vehicleId)
                item.put("account_id", row.accountId)
                item.put("key", row.key)
                item.put("value", row.value ?: JSONObject.NULL)
                item.put("status", row.status)
                item.put("decided_at_utc_millis", row.decidedAtUtcMillis)
                item.put("reported_at_utc_millis", row.reportedAtUtcMillis)
                payload.put(item)
            }
            request(
                method = "POST",
                url = url,
                jsonBody = payload.toString(),
                extraHeaders = mapOf("Prefer" to "resolution=ignore-duplicates,return=minimal"),
            )
        }
    }

    // --- transport plumbing -------------------------------------------------

    private fun restUrl(table: String, query: String): String {
        val base = baseUrl.trim().trimEnd('/')
        if (base.isEmpty()) {
            throw PreferenceControlCloudException(
                IllegalStateException("SUPABASE_URL not configured"),
                retryable = false,
            )
        }
        if (anonKey.isBlank()) {
            throw PreferenceControlCloudException(
                IllegalStateException("SUPABASE_ANON_KEY not configured"),
                retryable = false,
            )
        }
        val token = carTokenProvider()
        if (token.isNullOrBlank()) {
            throw PreferenceControlCloudException(
                IllegalStateException("car not paired: no car_token"),
                retryable = false,
            )
        }
        return "$base/rest/v1/$table?$query"
    }

    private fun enc(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    private fun parseArray(body: String): List<JSONObject> {
        if (body.isBlank()) return emptyList()
        val arr = JSONArray(body)
        return (0 until arr.length()).map { arr.getJSONObject(it) }
    }

    private fun request(
        method: String,
        url: String,
        jsonBody: String?,
        extraHeaders: Map<String, String> = emptyMap(),
    ): String {
        val requestBuilder = Request.Builder()
            .url(url)
            .header("apikey", anonKey)
            .header("x-car-token", carTokenProvider().orEmpty())
            .header("Accept", "application/json")
        extraHeaders.forEach { (k, v) -> requestBuilder.header(k, v) }

        val mediaType = "application/json; charset=utf-8".toMediaType()
        when (method) {
            "POST" -> {
                val body = (jsonBody ?: "").toRequestBody(mediaType)
                requestBuilder.post(body)
            }
            "GET" -> {
                requestBuilder.get()
            }
        }

        val request = requestBuilder.build()
        try {
            client.newCall(request).execute().use { response ->
                val code = response.code
                val body = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    throw PreferenceControlCloudException(
                        IllegalStateException("$method $url failed: HTTP $code: ${body.take(300)}"),
                        retryable = PreferenceControlCloudException.isRetryable(
                            IllegalStateException("HTTP $code")
                        ),
                    )
                }
                return body
            }
        } catch (e: PreferenceControlCloudException) {
            throw e
        } catch (e: Exception) {
            throw PreferenceControlCloudException(e)
        }
    }
}