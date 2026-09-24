package com.timhss.capyenergy.roadcast

import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import org.json.JSONObject

data class RoadcastReleaseArtifact(
    val file: String,
    val sha256: String,
    val sizeBytes: Long
)

data class RoadcastReleaseManifest(
    val manifestVersion: Int,
    val version: String,
    val releaseTag: String,
    val channel: String,
    val commit: String,
    val abi: String,
    val minAndroidApi: Int,
    val protocol: Int,
    val minClientProtocol: Int,
    val maxClientProtocol: Int,
    val schemaVersion: Int,
    val daemon: RoadcastReleaseArtifact
) {
    fun compatibilityError(
        sdkInt: Int,
        supportedAbis: Collection<String>,
        clientProtocol: Int
    ): String? = when {
        manifestVersion != SUPPORTED_MANIFEST_VERSION ->
            "Unsupported Roadcast manifest version $manifestVersion"
        releaseTag != EDGE_TAG || channel != EDGE_TAG ->
            "Only the Roadcast edge channel is supported"
        abi !in supportedAbis ->
            "Roadcast ABI $abi is not supported by this device"
        sdkInt < minAndroidApi ->
            "Roadcast requires Android API $minAndroidApi"
        protocol !in minClientProtocol..maxClientProtocol ->
            "Roadcast manifest has an invalid protocol range"
        clientProtocol !in minClientProtocol..maxClientProtocol ->
            "Roadcast protocol $protocol is incompatible with client protocol $clientProtocol"
        else -> null
    }

    companion object {
        const val SUPPORTED_MANIFEST_VERSION = 1
        const val CLIENT_PROTOCOL_VERSION = 3
        const val EDGE_TAG = "edge"
        const val DAEMON_FILE = "roadcastd"
        const val MAX_DAEMON_BYTES = 16L * 1024L * 1024L
        private val SHA256_PATTERN = Regex("^[0-9a-f]{64}$")
        private val COMMIT_PATTERN = Regex("^[0-9a-f]{40}$")

        fun parse(json: String): RoadcastReleaseManifest {
            val root = JSONObject(json)
            val artifacts = root.getJSONObject("artifacts")
            val daemonJson = artifacts.getJSONObject(DAEMON_FILE)
            val daemon = RoadcastReleaseArtifact(
                file = daemonJson.getString("file"),
                sha256 = daemonJson.getString("sha256").lowercase(),
                sizeBytes = daemonJson.getLong("sizeBytes")
            )
            val manifest = RoadcastReleaseManifest(
                manifestVersion = root.getInt("manifestVersion"),
                version = root.getString("version"),
                releaseTag = root.getString("releaseTag"),
                channel = root.getString("channel"),
                commit = root.getString("commit").lowercase(),
                abi = root.getString("abi"),
                minAndroidApi = root.getInt("minAndroidApi"),
                protocol = root.getInt("protocol"),
                minClientProtocol = root.getInt("minClientProtocol"),
                maxClientProtocol = root.getInt("maxClientProtocol"),
                schemaVersion = root.getInt("schemaVersion"),
                daemon = daemon
            )
            require(manifest.version.isNotBlank()) { "Roadcast version is empty" }
            require(COMMIT_PATTERN.matches(manifest.commit)) { "Invalid Roadcast commit" }
            require(manifest.minAndroidApi > 0) { "Invalid minimum Android API" }
            require(manifest.protocol > 0) { "Invalid Roadcast protocol" }
            require(manifest.minClientProtocol > 0) { "Invalid minimum client protocol" }
            require(manifest.maxClientProtocol >= manifest.minClientProtocol) {
                "Invalid client protocol range"
            }
            require(manifest.schemaVersion > 0) { "Invalid Roadcast schema version" }
            require(daemon.file == DAEMON_FILE) { "Unexpected Roadcast daemon filename" }
            require(SHA256_PATTERN.matches(daemon.sha256)) { "Invalid Roadcast daemon SHA-256" }
            require(daemon.sizeBytes in 1..MAX_DAEMON_BYTES) {
                "Invalid Roadcast daemon size"
            }
            return manifest
        }

        fun sha256(file: File): String = file.inputStream().use(::sha256)

        fun sha256(input: InputStream): String {
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (read > 0) digest.update(buffer, 0, read)
            }
            return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
        }
    }
}
