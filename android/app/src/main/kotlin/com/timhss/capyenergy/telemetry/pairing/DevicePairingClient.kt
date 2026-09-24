package com.timhss.capyenergy.telemetry.pairing

import com.timhss.capyenergy.BuildConfig
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Result of `POST {base}/device-pairing/start`.
 *
 * Mirrors `supabase/functions/device-pairing/index.ts` `handleStart`
 * which returns `{user_code, device_code, expires_at}` with 201.
 */
data class PairingStartResult(
    val userCode: String,
    val deviceCode: String,
    val expiresAt: String
)

/**
 * Result of `POST {base}/device-pairing/register`.
 *
 * Mirrors `supabase/functions/device-pairing/index.ts` `handleRegister`
 * which returns `{car_token}` with 201.
 */
data class RegisterResult(
    val carToken: String
)

/**
 * Result of `POST {base}/device-pairing/poll`.
 *
 * Distinguishable error reasons mirror the server's `pairing.ts`
 * `claimErrorReason` / `resolvePollStatus` design:
 * `invalid_code` (404 or 400) vs `expired` (200 with status=expired).
 */
sealed class PairingPollResult {
    /** Still waiting for the user to claim on their phone. */
    object Pending : PairingPollResult()
    /** Pairing approved — contains the scoped car credential. */
    data class Approved(val carToken: String, val accountId: String) : PairingPollResult()
    /** Session expired (timeout or explicitly expired). */
    object Expired : PairingPollResult()
    /** Phone explicitly declined the pairing request. */
    object Rejected : PairingPollResult()
    /** Unknown or malformed device_code. */
    object InvalidCode : PairingPollResult()
}

/**
 * Pluggable pairing network dependency.
 *
 * Mirrors the [com.timhss.capyenergy.telemetry.sync.CloudSink] seam:
 * one interface, a real JDK-HTTP implementation and a fake for tests.
 */
interface DevicePairingClient {
    suspend fun start(vehicleId: String): PairingStartResult
    suspend fun register(vehicleId: String): RegisterResult
    suspend fun poll(deviceCode: String): PairingPollResult
}

/**
 * Thrown when the pairing endpoint cannot be reached or returns an
 * unparseable error. Distinguishable `Expired` / `InvalidCode`
 * are returned as [PairingPollResult] values, not exceptions.
 */
class DevicePairingException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Real implementation using the JDK's [HttpURLConnection].
 *
 * The cloud uploads and the control plane use the shared OkHttp client in
 * [com.timhss.capyenergy.telemetry.sync.OkHttpProvider]; pairing makes a few
 * one-shot calls and has not moved to it. Min SDK 28 supports
 * `HttpURLConnection` everywhere; `java.net.http.HttpClient` requires API 34
 * and is not used.
 *
 * [baseUrl] defaults to the build-configured [BuildConfig.SUPABASE_FUNCTIONS_URL]
 * (empty string when no Supabase project is wired) and may be overridden
 * in tests.
 */
class HttpDevicePairingClient(
    private val baseUrl: String = BuildConfig.SUPABASE_FUNCTIONS_URL
) : DevicePairingClient {

    override suspend fun start(vehicleId: String): PairingStartResult = withContext(Dispatchers.IO) {
        val url = resolveUrl("/device-pairing/start")
        val body = JSONObject().apply { put("vehicle_id", vehicleId) }.toString()
        val response = postJson(url, body)
        if (response.code !in 200..299) {
            val parsed = parseError(response.body)
            throw DevicePairingException("start failed ${response.code}: ${parsed ?: response.body}")
        }
        val json = JSONObject(response.body)
        PairingStartResult(
            userCode = json.getString("user_code"),
            deviceCode = json.getString("device_code"),
            expiresAt = json.getString("expires_at")
        )
    }

    override suspend fun register(vehicleId: String): RegisterResult = withContext(Dispatchers.IO) {
        val url = resolveUrl("/device-pairing/register")
        val body = JSONObject().apply { put("vehicle_id", vehicleId) }.toString()
        val response = postJson(url, body)
        if (response.code !in 200..299) {
            val parsed = parseError(response.body)
            throw DevicePairingException("register failed ${response.code}: ${parsed ?: response.body}")
        }
        val json = JSONObject(response.body)
        RegisterResult(
            carToken = json.getString("car_token")
        )
    }

    override suspend fun poll(deviceCode: String): PairingPollResult = withContext(Dispatchers.IO) {
        val url = resolveUrl("/device-pairing/poll")
        val body = JSONObject().apply { put("device_code", deviceCode) }.toString()
        val response = postJson(url, body)
        if (response.code == 400 || response.code == 404) {
            val reason = parseReason(response.body)
            if (reason == "invalid_code") return@withContext PairingPollResult.InvalidCode
            if (reason == "rejected") return@withContext PairingPollResult.Rejected
            if (reason == "expired") return@withContext PairingPollResult.Expired
            // Fallback: treat any 4xx with unknown reason as InvalidCode when code suggests it,
            // otherwise as Expired/Rejected if body says so.
            if (response.body.contains("\"rejected\"", ignoreCase = true)) {
                return@withContext PairingPollResult.Rejected
            }
            if (response.body.contains("\"expired\"", ignoreCase = true)) {
                return@withContext PairingPollResult.Expired
            }
            return@withContext PairingPollResult.InvalidCode
        }
        if (response.code !in 200..299) {
            throw DevicePairingException("poll failed ${response.code}: ${response.body}")
        }
        val json = JSONObject(response.body)
        when (val status = json.optString("status", "")) {
            "pending" -> PairingPollResult.Pending
            "approved" -> {
                val carToken = json.optString("car_token", "")
                val accountId = json.optString("account_id", "")
                if (carToken.isBlank() || accountId.isBlank()) {
                    throw DevicePairingException("approved response missing car_token/account_id: ${response.body}")
                }
                PairingPollResult.Approved(carToken, accountId)
            }
            "expired" -> PairingPollResult.Expired
            "rejected" -> PairingPollResult.Rejected
            else -> {
                // Fallback: check reason field
                val reason = json.optString("reason", "")
                if (reason == "expired") PairingPollResult.Expired
                else if (reason == "rejected") PairingPollResult.Rejected
                else if (reason == "invalid_code") PairingPollResult.InvalidCode
                else throw DevicePairingException("unknown poll status '$status': ${response.body}")
            }
        }
    }

    private fun resolveUrl(path: String): String {
        val base = baseUrl.trim().trimEnd('/')
        if (base.isEmpty()) {
            throw DevicePairingException("SUPABASE_FUNCTIONS_URL not configured")
        }
        return "$base$path"
    }

    private data class HttpResponse(val code: Int, val body: String)

    private fun postJson(urlString: String, jsonBody: String): HttpResponse {
        val url = URL(urlString)
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 10_000
            readTimeout = 10_000
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Accept", "application/json")
        }
        try {
            conn.outputStream.use { os ->
                os.write(jsonBody.toByteArray(Charsets.UTF_8))
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val body = if (stream != null) {
                BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).use { it.readText() }
            } else {
                ""
            }
            return HttpResponse(code, body)
        } finally {
            conn.disconnect()
        }
    }

    private fun parseReason(body: String): String? = try {
        val value = JSONObject(body).optString("reason", "")
        value.takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        null
    }

    private fun parseError(body: String): String? = try {
        val json = JSONObject(body)
        val msg = json.optString("message", "")
        if (msg.isNotBlank()) msg else {
            val reason = json.optString("reason", "")
            reason.takeIf { it.isNotBlank() }
        }
    } catch (_: Exception) {
        null
    }
}

/**
 * In-memory fake for unit tests — no network.
 *
 * Queue-based: enqueue the result you want each call to return.
 * If no queued response exists, sensible defaults are returned
 * (`Pending` for poll, a synthetic start result).
 */
class FakeDevicePairingClient : DevicePairingClient {
    data class StartResponse(val result: PairingStartResult?, val error: Throwable? = null)
    data class RegisterResponse(val result: RegisterResult?, val error: Throwable? = null)

    val startCalls = mutableListOf<String>()
    val registerCalls = mutableListOf<String>()
    val pollCalls = mutableListOf<String>()

    private val startQueue = ArrayDeque<StartResponse>()
    private val registerQueue = ArrayDeque<RegisterResponse>()
    private val pollQueue = ArrayDeque<PairingPollResult>()
    private val pollErrorQueue = ArrayDeque<Throwable>()

    var defaultStartResult = PairingStartResult(
        userCode = "123-456",
        deviceCode = "00000000-0000-4000-a000-000000000001",
        expiresAt = "2099-01-01T00:00:00.000Z"
    )

    var defaultRegisterResult = RegisterResult(
        carToken = "test-car-token"
    )
    fun enqueueStart(result: PairingStartResult) {
        startQueue.addLast(StartResponse(result, null))
    }

    fun enqueueStartError(error: Throwable) {
        startQueue.addLast(StartResponse(null, error))
    }

    fun enqueueRegister(result: RegisterResult) {
        registerQueue.addLast(RegisterResponse(result, null))
    }

    fun enqueueRegisterError(error: Throwable) {
        registerQueue.addLast(RegisterResponse(null, error))
    }

    fun enqueuePoll(result: PairingPollResult) {
        pollQueue.addLast(result)
    }

    fun enqueuePollError(error: Throwable) {
        pollErrorQueue.addLast(error)
    }

    override suspend fun start(vehicleId: String): PairingStartResult {
        startCalls.add(vehicleId)
        val next = startQueue.removeFirstOrNull()
        if (next != null) {
            next.error?.let { throw it }
            return next.result ?: defaultStartResult
        }
        return defaultStartResult
    }

    override suspend fun register(vehicleId: String): RegisterResult {
        registerCalls.add(vehicleId)
        val next = registerQueue.removeFirstOrNull()
        if (next != null) {
            next.error?.let { throw it }
            return next.result ?: defaultRegisterResult
        }
        return defaultRegisterResult
    }

    override suspend fun poll(deviceCode: String): PairingPollResult {
        pollCalls.add(deviceCode)
        pollErrorQueue.removeFirstOrNull()?.let { throw it }
        return pollQueue.removeFirstOrNull() ?: PairingPollResult.Pending
    }

    fun reset() {
        startCalls.clear()
        registerCalls.clear()
        pollCalls.clear()
        startQueue.clear()
        registerQueue.clear()
        pollQueue.clear()
        pollErrorQueue.clear()
    }
}
