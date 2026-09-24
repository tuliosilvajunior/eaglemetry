package com.timhss.capyenergy.roadcast

import android.content.Context
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

data class RoadcastPreparedUpdate(
    val release: StoredRoadcastRelease,
    val previousActiveDigest: String?
)

data class RoadcastUpdateStatus(
    val checked: Boolean,
    val updateAvailable: Boolean,
    val compatible: Boolean,
    val installedSha256: String?,
    val installedVersion: String?,
    val installedCommit: String?,
    val availableVersion: String?,
    val availableCommit: String?,
    val availableSha256: String?,
    val error: String? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "checked" to checked,
        "channel" to RoadcastReleaseManifest.EDGE_TAG,
        "updateAvailable" to updateAvailable,
        "compatible" to compatible,
        "installedSha256" to installedSha256,
        "installedVersion" to installedVersion,
        "installedCommit" to installedCommit,
        "availableVersion" to availableVersion,
        "availableCommit" to availableCommit,
        "availableSha256" to availableSha256,
        "error" to error
    )
}

internal interface RoadcastDownloader {
    fun read(url: URL, maxBytes: Long): ByteArray
    fun download(url: URL, destination: File, expectedBytes: Long)
}

internal class HttpRoadcastDownloader : RoadcastDownloader {
    override fun read(url: URL, maxBytes: Long): ByteArray {
        val connection = open(url)
        return try {
            val declared = connection.contentLengthLong
            require(declared <= maxBytes || declared < 0) { "Roadcast response is too large" }
            val output = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    require(total <= maxBytes) { "Roadcast response is too large" }
                    output.write(buffer, 0, read)
                }
            }
            output.toByteArray()
        } finally {
            connection.disconnect()
        }
    }

    override fun download(url: URL, destination: File, expectedBytes: Long) {
        val connection = open(url)
        try {
            val declared = connection.contentLengthLong
            require(declared == expectedBytes || declared < 0) {
                "Roadcast download size does not match the manifest"
            }
            var total = 0L
            connection.inputStream.use { input ->
                FileOutputStream(destination).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        require(total <= expectedBytes) {
                            "Roadcast download exceeded the manifest size"
                        }
                        output.write(buffer, 0, read)
                    }
                    output.fd.sync()
                }
            }
            require(total == expectedBytes) { "Roadcast download is incomplete" }
        } finally {
            connection.disconnect()
        }
    }

    private fun open(url: URL): HttpURLConnection {
        require(url.protocol == "https") { "Roadcast updates require HTTPS" }
        return (url.openConnection() as HttpURLConnection).apply {
            connectTimeout = CONNECT_TIMEOUT_MILLIS
            readTimeout = READ_TIMEOUT_MILLIS
            instanceFollowRedirects = true
            useCaches = false
            setRequestProperty("Accept", "application/octet-stream, application/json")
            setRequestProperty("User-Agent", "Capy-Roadcast-Updater")
            connect()
            val status = responseCode
            require(this.url.protocol == "https") {
                "Roadcast download redirected to an insecure URL"
            }
            check(status in 200..299) {
                "Roadcast download failed with HTTP $status"
            }
        }
    }

    private companion object {
        const val CONNECT_TIMEOUT_MILLIS = 10_000
        const val READ_TIMEOUT_MILLIS = 30_000
    }
}

class RoadcastUpdateManager internal constructor(
    context: Context,
    private val store: RoadcastBinaryStore = RoadcastBinaryStore(context),
    private val downloader: RoadcastDownloader = HttpRoadcastDownloader()
) {
    private val appContext = context.applicationContext

    fun localStatus(installedSha256: String?): RoadcastUpdateStatus {
        val active = store.activeRelease()?.manifest
        return RoadcastUpdateStatus(
            checked = false,
            updateAvailable = false,
            compatible = true,
            installedSha256 = installedSha256,
            installedVersion = active?.version,
            installedCommit = active?.commit,
            availableVersion = null,
            availableCommit = null,
            availableSha256 = null
        )
    }

    fun check(installedSha256: String?): RoadcastUpdateStatus {
        val manifest = fetchManifest()
        val compatibilityError = compatibilityError(manifest)
        val active = store.activeRelease()?.manifest
        return RoadcastUpdateStatus(
            checked = true,
            updateAvailable = compatibilityError == null &&
                installedSha256 != manifest.daemon.sha256,
            compatible = compatibilityError == null,
            installedSha256 = installedSha256,
            installedVersion = active?.version,
            installedCommit = active?.commit,
            availableVersion = manifest.version,
            availableCommit = manifest.commit,
            availableSha256 = manifest.daemon.sha256,
            error = compatibilityError
        )
    }

    fun prepare(installedSha256: String?): RoadcastPreparedUpdate {
        val manifestJson = downloader.read(URL(MANIFEST_URL), MAX_MANIFEST_BYTES)
            .toString(Charsets.UTF_8)
        val manifest = RoadcastReleaseManifest.parse(manifestJson)
        compatibilityError(manifest)?.let(::error)
        require(installedSha256 != manifest.daemon.sha256) {
            "Roadcast edge is already installed"
        }

        val temporary = File(appContext.cacheDir, "roadcastd.download")
        try {
            downloader.download(
                URL(DAEMON_URL),
                temporary,
                manifest.daemon.sizeBytes
            )
            val release = store.stage(manifest, manifestJson, temporary)
            return RoadcastPreparedUpdate(release, store.activeDigest())
        } finally {
            temporary.delete()
        }
    }

    fun activate(prepared: RoadcastPreparedUpdate) = store.activate(prepared.release)

    fun restorePrevious(prepared: RoadcastPreparedUpdate) =
        store.restoreActiveDigest(prepared.previousActiveDigest)

    fun discard(prepared: RoadcastPreparedUpdate) = store.discard(prepared.release)

    fun completed(prepared: RoadcastPreparedUpdate): RoadcastUpdateStatus {
        val manifest = prepared.release.manifest
        return RoadcastUpdateStatus(
            checked = true,
            updateAvailable = false,
            compatible = true,
            installedSha256 = manifest.daemon.sha256,
            installedVersion = manifest.version,
            installedCommit = manifest.commit,
            availableVersion = manifest.version,
            availableCommit = manifest.commit,
            availableSha256 = manifest.daemon.sha256
        )
    }

    private fun fetchManifest(): RoadcastReleaseManifest {
        val json = downloader.read(URL(MANIFEST_URL), MAX_MANIFEST_BYTES)
            .toString(Charsets.UTF_8)
        return RoadcastReleaseManifest.parse(json)
    }

    private fun compatibilityError(manifest: RoadcastReleaseManifest): String? =
        manifest.compatibilityError(
            sdkInt = Build.VERSION.SDK_INT,
            supportedAbis = Build.SUPPORTED_ABIS.toList(),
            clientProtocol = RoadcastReleaseManifest.CLIENT_PROTOCOL_VERSION
        )

    private companion object {
        const val MAX_MANIFEST_BYTES = 64L * 1024L
        const val MANIFEST_URL =
            "https://github.com/Timoteohss/roadcast/releases/download/edge/RELEASE_MANIFEST.json"
        const val DAEMON_URL =
            "https://github.com/Timoteohss/roadcast/releases/download/edge/roadcastd"
    }
}
