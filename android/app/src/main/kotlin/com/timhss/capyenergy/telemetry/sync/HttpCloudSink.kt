package com.timhss.capyenergy.telemetry.sync

import android.os.SystemClock
import com.timhss.capyenergy.BuildConfig
import com.timhss.capyenergy.telemetry.ClockAnchorStore
import java.net.URLEncoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray

/**
 * Real [CloudSink] over PostgREST via [OkHttpClient] with connection pooling
 * and HTTP/2 multiplexing.
 *
 * Used for Lanes A/B (telemetry + annotations) when the cloud-sync gate
 * ([BuildConfig.CLOUD_SYNC_ENABLED]) is on, which is the default. Every prior
 * phase shipped with
 * [com.timhss.capyenergy.telemetry.TelemetryGraph.NoOpCloudSink] inert; an
 * explicit `false` still restores that inert behavior — see the gate
 * documented in `android/app/build.gradle.kts` and
 * [com.timhss.capyenergy.telemetry.TelemetryGraph].
 *
 * Transport (mirrors the companion's `SupabaseCloudSink`):
 *
 * ```
 * apikey: <anon key>
 * x-car-token: <raw car_token>   // when paired; empty otherwise
 * Content-Type: application/json
 * Prefer: resolution=merge-duplicates (merge=true) or ignore-duplicates (merge=false), return=minimal
 * ```
 *
 * Without a user JWT the request runs as `anon` with `x-car-token`; the
 * device-token RLS on the telemetry/annotation tables
 * (`20260902190000_car_device_telemetry_rls.sql`) admits it. A PostgREST
 * refusal surfaces as a non-retryable [TelemetryCloudUploadException].
 *
 * Credentials are sourced from the already-established mechanism:
 * [BuildConfig.SUPABASE_URL] / [BuildConfig.SUPABASE_ANON_KEY] (populated
 * from `local.properties` → gradle property → env, same as
 * [com.timhss.capyenergy.telemetry.control.HttpPreferenceControlCloud] and
 * [com.timhss.capyenergy.telemetry.pairing.HttpDevicePairingClient]).
 *
 * A PostgREST refusal surfaces as [HttpCloudSinkException] with its
 * structured HTTP status (below), never as message text: the message embeds
 * the request URL and body, where 409/422-shaped digits occur naturally.
 */
class HttpCloudSinkException(
    val statusCode: Int,
    message: String,
) : Exception(message)

class HttpCloudSink(
    private val baseUrl: String = BuildConfig.SUPABASE_URL,
    private val anonKey: String = BuildConfig.SUPABASE_ANON_KEY,
    private val carTokenProvider: () -> String? = { null },
    private val anchorStore: ClockAnchorStore = ClockAnchorStore,
    private val monotonicNanos: () -> Long = { SystemClock.elapsedRealtimeNanos() },
    private val client: OkHttpClient = OkHttpProvider.client,
) : CloudSink {

    override suspend fun upsert(
        table: String,
        rows: List<Map<String, Any?>>,
        conflictColumns: List<String>,
        merge: Boolean,
    ) {
        if (rows.isEmpty()) return
        withContext(Dispatchers.IO) {
            val url = restUrl(table, conflictColumns, merge)
            val payload = buildPayload(rows, stripNulls = table !in preserveNullsTables)
            request("POST", url, payload, merge)
        }
    }

    override suspend fun delete(
        table: String,
        vehicleId: String,
        keys: List<Triple<String, String, Long>>
    ) {
        if (keys.isEmpty()) return
        withContext(Dispatchers.IO) {
            // Group by sessionId so start_utc_millis only matches intervals of that exact session,
            // avoiding a Cartesian product across multiple sessions.
            val bySession = keys.groupBy { it.second }
            val encodedVehicle = URLEncoder.encode(vehicleId, Charsets.UTF_8.name())
            val base = baseUrl.trim().trimEnd('/')
            for ((sessionId, sessionKeys) in bySession) {
                val encodedSession = URLEncoder.encode(sessionId, Charsets.UTF_8.name())
                // Sub-batch stamps in chunks of 50 to remain well within URL length limits.
                for (chunk in sessionKeys.chunked(50)) {
                    val stamps = chunk.map { it.third }.distinct().joinToString(",")
                    val url = "$base/rest/v1/$table" +
                        "?vehicle_id=eq.$encodedVehicle" +
                        "&session_id=eq.$encodedSession" +
                        "&start_utc_millis=in.($stamps)"
                    request("DELETE", url, null, merge = true)
                }
            }
        }
    }

    override suspend fun ownedVehicles(ids: Set<String>): Set<String> {
        if (ids.isEmpty()) return emptySet()
        // Companion scopes this via RLS `select vehicle where account_id = auth.uid()`.
        // The car side uses the same sink contract but has no authenticated read
        // path for this yet; return the input so the uploader does not spuriously
        // claim a conflict. A future device-token RLS can make this a real query.
        return emptySet()
    }

    private fun restUrl(table: String, conflictColumns: List<String>, merge: Boolean): String {
        val base = baseUrl.trim().trimEnd('/')
        if (base.isEmpty()) {
            throw TelemetryCloudUploadException(
                table = table,
                cause = IllegalStateException("SUPABASE_URL not configured"),
                retryable = false,
            )
        }
        if (anonKey.isBlank()) {
            throw TelemetryCloudUploadException(
                table = table,
                cause = IllegalStateException("SUPABASE_ANON_KEY not configured"),
                retryable = false,
            )
        }
        val conflict = if (conflictColumns.isNotEmpty()) {
            "on_conflict=${conflictColumns.joinToString(",") { URLEncoder.encode(it, Charsets.UTF_8.name()) }}"
        } else {
            ""
        }
        return "$base/rest/v1/$table?$conflict"
    }

    /**
     * Tables whose explicit nulls must reach Postgres untouched. The
     * annotation merge trigger (`supabase/migrations/
     * 20260902130000_annotation_merge_trigger.sql`) reads
     * `NEW.deleted_at_utc_millis` to tell alive from deleted: an omitted
     * tombstone arrives as "still deleted" and would pin a cloud-deleted row
     * deleted forever, where an explicit null lets a newer field edit
     * resurrect it. Telemetry tables have no such trigger — plain
     * `ON CONFLICT ... DO UPDATE` leaves an omitted column untouched — and
     * their columns only ever fill forward (open upload, then close upload),
     * so omitting nulls there is both smaller and safer.
     */
    private val preserveNullsTables = setOf(
        "insight_places",
        "session_costs",
        "journeys",
        "preferences",
        "telemetry_events"
    )

    // Null keys are omitted, not sent as JSON null: under
    // `Prefer: resolution=merge-duplicates` PostgREST builds
    // `ON CONFLICT ... DO UPDATE` from the keys present, so an omitted key
    // leaves the existing column untouched while an explicit null would wipe
    // it (e.g. a session re-uploaded on close wiping a column the open
    // upload had set). Bonus: unset nullable columns stop costing bytes.
    private fun buildPayload(rows: List<Map<String, Any?>>, stripNulls: Boolean): String {
        val arr = JSONArray()
        for (row in rows) {
            val obj = org.json.JSONObject()
            for ((k, v) in row) {
                if (v != null || !stripNulls) obj.put(k, v ?: org.json.JSONObject.NULL)
            }
            arr.put(obj)
        }
        return arr.toString()
    }

    private fun request(
        method: String,
        url: String,
        jsonBody: String?,
        merge: Boolean,
    ): String {
        val requestBuilder = Request.Builder()
            .url(url)
            .header("apikey", anonKey)
            .header("Accept", "application/json")

        val token = carTokenProvider()
        if (!token.isNullOrBlank()) {
            requestBuilder.header("x-car-token", token)
        }

        val prefer = if (method == "DELETE") {
            "return=minimal"
        } else {
            val resolution = if (merge) "resolution=merge-duplicates" else "resolution=ignore-duplicates"
            "$resolution, return=minimal"
        }
        requestBuilder.header("Prefer", prefer)

        val mediaType = "application/json; charset=utf-8".toMediaType()
        when (method) {
            "POST" -> {
                val body = (jsonBody ?: "[]").toRequestBody(mediaType)
                requestBuilder.post(body)
            }
            "DELETE" -> {
                requestBuilder.delete()
            }
            "GET" -> {
                requestBuilder.get()
            }
        }

        val request = requestBuilder.build()
        try {
            client.newCall(request).execute().use { response ->
                val code = response.code
                val elapsedNanos = try {
                    monotonicNanos()
                } catch (_: Exception) {
                    0L
                }
                val body = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    val ex = HttpCloudSinkException(code, "$method $url failed: HTTP $code: ${body.take(500)}")
                    throw TelemetryCloudUploadException(
                        table = extractTable(url),
                        cause = ex,
                        retryable = TelemetryCloudUploadException.isRetryable(ex),
                    )
                }
                if (elapsedNanos > 0L) {
                    offerServerDate(response.header("Date"), elapsedNanos)
                }
                return body
            }
        } catch (e: TelemetryCloudUploadException) {
            throw e
        } catch (e: Exception) {
            throw TelemetryCloudUploadException(
                table = extractTable(url),
                cause = e,
                retryable = TelemetryCloudUploadException.isRetryable(e),
            )
        }
    }

    /**
     * Reads the server `Date` header on a successful response and offers
     * `(serverDateMillis, elapsedRealtimeNanos)` to the anchor store. Hostile
     * headers (absent, malformed, wrong) never throw and never touch the
     * row pipeline — the store's rule rejects a shifted Date.
     */
    private fun offerServerDate(header: String?, elapsedNanos: Long) {
        val serverMillis = anchorStore.parseHttpDateHeader(header) ?: return
        anchorStore.offerServerDate(serverMillis, elapsedNanos)
    }

    private fun extractTable(url: String): String =
        url.substringAfter("/rest/v1/").substringBefore("?").substringBefore("&")
}
