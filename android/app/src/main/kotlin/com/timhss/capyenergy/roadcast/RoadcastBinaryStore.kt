package com.timhss.capyenergy.roadcast

import android.content.Context
import android.os.Build
import java.io.File
import java.io.FileOutputStream

data class StoredRoadcastRelease(
    val manifest: RoadcastReleaseManifest,
    val manifestJson: String,
    val daemonFile: File
)

class RoadcastBinaryStore(context: Context) {
    private val appContext = context.applicationContext
    private val releasesDir = File(appContext.filesDir, RELEASES_DIRECTORY)
    private val preferences =
        appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    fun activeRelease(): StoredRoadcastRelease? {
        val digest = activeDigest() ?: return null
        return loadRelease(digest)?.takeIf(::isCompatible)
    }

    fun activeDigest(): String? = preferences.getString(ACTIVE_DIGEST_KEY, null)

    fun stage(manifest: RoadcastReleaseManifest, manifestJson: String, source: File): StoredRoadcastRelease {
        require(source.isFile) { "Downloaded Roadcast daemon is missing" }
        require(source.length() == manifest.daemon.sizeBytes) {
            "Downloaded Roadcast daemon size does not match the manifest"
        }
        require(RoadcastReleaseManifest.sha256(source) == manifest.daemon.sha256) {
            "Downloaded Roadcast daemon checksum does not match the manifest"
        }

        val releaseDir = File(releasesDir, manifest.daemon.sha256)
        check(releaseDir.mkdirs() || releaseDir.isDirectory) {
            "Failed to create Roadcast release directory"
        }
        val daemonFile = File(releaseDir, RoadcastReleaseManifest.DAEMON_FILE)
        val manifestFile = File(releaseDir, MANIFEST_FILE)
        writeAtomically(source, daemonFile)
        writeAtomically(manifestJson.toByteArray(Charsets.UTF_8), manifestFile)
        return loadRelease(manifest.daemon.sha256)
            ?: error("Stored Roadcast release failed validation")
    }

    fun activate(release: StoredRoadcastRelease) {
        check(preferences.edit().putString(ACTIVE_DIGEST_KEY, release.manifest.daemon.sha256).commit()) {
            "Failed to persist the active Roadcast release"
        }
    }

    fun restoreActiveDigest(digest: String?) {
        val editor = preferences.edit()
        if (digest == null) {
            editor.remove(ACTIVE_DIGEST_KEY)
        } else {
            editor.putString(ACTIVE_DIGEST_KEY, digest)
        }
        check(editor.commit()) { "Failed to restore the previous Roadcast release" }
    }

    fun discard(release: StoredRoadcastRelease) {
        if (preferences.getString(ACTIVE_DIGEST_KEY, null) == release.manifest.daemon.sha256) return
        release.daemonFile.parentFile?.deleteRecursively()
    }

    private fun loadRelease(digest: String): StoredRoadcastRelease? {
        if (!SHA256_PATTERN.matches(digest)) return null
        val releaseDir = File(releasesDir, digest)
        val daemonFile = File(releaseDir, RoadcastReleaseManifest.DAEMON_FILE)
        val manifestFile = File(releaseDir, MANIFEST_FILE)
        if (!daemonFile.isFile || !manifestFile.isFile) return null
        return runCatching {
            val manifestJson = manifestFile.readText(Charsets.UTF_8)
            val manifest = RoadcastReleaseManifest.parse(manifestJson)
            check(manifest.daemon.sha256 == digest)
            check(daemonFile.length() == manifest.daemon.sizeBytes)
            check(RoadcastReleaseManifest.sha256(daemonFile) == digest)
            StoredRoadcastRelease(manifest, manifestJson, daemonFile)
        }.getOrNull()
    }

    private fun isCompatible(release: StoredRoadcastRelease): Boolean =
        release.manifest.compatibilityError(
            sdkInt = Build.VERSION.SDK_INT,
            supportedAbis = Build.SUPPORTED_ABIS.toList(),
            clientProtocol = RoadcastReleaseManifest.CLIENT_PROTOCOL_VERSION
        ) == null

    private fun writeAtomically(source: File, destination: File) {
        val temporary = File(destination.parentFile, "${destination.name}.tmp")
        source.inputStream().use { input ->
            FileOutputStream(temporary).use { output ->
                input.copyTo(output)
                output.fd.sync()
            }
        }
        replace(temporary, destination)
    }

    private fun writeAtomically(bytes: ByteArray, destination: File) {
        val temporary = File(destination.parentFile, "${destination.name}.tmp")
        FileOutputStream(temporary).use { output ->
            output.write(bytes)
            output.fd.sync()
        }
        replace(temporary, destination)
    }

    private fun replace(temporary: File, destination: File) {
        if (destination.exists() && !destination.delete()) {
            temporary.delete()
            error("Failed to replace ${destination.name}")
        }
        if (!temporary.renameTo(destination)) {
            temporary.delete()
            error("Failed to activate ${destination.name}")
        }
    }

    private companion object {
        const val RELEASES_DIRECTORY = "roadcast/releases"
        const val PREFERENCES_NAME = "roadcast_updates"
        const val ACTIVE_DIGEST_KEY = "active_daemon_sha256"
        const val MANIFEST_FILE = "RELEASE_MANIFEST.json"
        val SHA256_PATTERN = Regex("^[0-9a-f]{64}$")
    }
}
