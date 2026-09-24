package com.timhss.capyenergy.update

import java.net.URL
import org.json.JSONArray
import org.json.JSONObject

data class AppChangelogEntry(
    val versionName: String,
    val versionCode: Long,
    val notes: Map<String, List<String>>
) {
    fun toMap(): Map<String, Any> = mapOf(
        "versionName" to versionName,
        "versionCode" to versionCode,
        "notes" to notes
    )
}

data class AppUpdateManifest(
    val schemaVersion: Int,
    val versionName: String,
    val versionCode: Long,
    val packageName: String,
    val apkUrl: String,
    val sha256: String,
    val sizeBytes: Long,
    val requiresReflash: Boolean,
    val changelog: List<AppChangelogEntry>
) {
    companion object {
        const val SUPPORTED_SCHEMA_VERSION = 1
        const val PACKAGE_NAME = "com.timhss.capy"
        const val MAX_APK_BYTES = 250L * 1024L * 1024L
        private const val RELEASE_PATH_SEGMENT = "/releases/download/"
        private val SHA256_PATTERN = Regex("^[0-9a-f]{64}$")
        private val VERSION_NAME_PATTERN = Regex("^\\d+\\.\\d+\\.\\d+(?:[-+][0-9A-Za-z.-]+)?$")

        fun parse(json: String, expectedPackage: String = PACKAGE_NAME): AppUpdateManifest {
            val root = JSONObject(json)
            val manifest = AppUpdateManifest(
                schemaVersion = root.getInt("schemaVersion"),
                versionName = root.getString("versionName"),
                versionCode = root.getLong("versionCode"),
                packageName = root.getString("packageName"),
                apkUrl = root.getString("apkUrl"),
                sha256 = root.getString("sha256").lowercase(),
                sizeBytes = root.getLong("sizeBytes"),
                requiresReflash = root.getBoolean("requiresReflash"),
                changelog = parseChangelog(root.optJSONArray("changelog"))
            )
            require(manifest.schemaVersion == SUPPORTED_SCHEMA_VERSION) {
                "Unsupported app update manifest version ${manifest.schemaVersion}"
            }
            require(VERSION_NAME_PATTERN.matches(manifest.versionName)) {
                "Invalid app update version name"
            }
            require(manifest.versionCode > 0) { "Invalid app update version code" }
            require(manifest.packageName == expectedPackage) {
                "Unexpected app update package ${manifest.packageName}"
            }
            require(SHA256_PATTERN.matches(manifest.sha256)) {
                "Invalid app update SHA-256"
            }
            require(manifest.sizeBytes in 1..MAX_APK_BYTES) {
                "Invalid app update APK size"
            }
            validateApkUrl(manifest.apkUrl)
            require(manifest.changelog.all { it.versionCode <= manifest.versionCode }) {
                "App changelog contains a future version"
            }
            return manifest
        }

        private fun parseChangelog(value: JSONArray?): List<AppChangelogEntry> {
            if (value == null) return emptyList()
            require(value.length() <= MAX_CHANGELOG_ENTRIES) {
                "App changelog has too many entries"
            }
            return List(value.length()) { index ->
                val entry = value.getJSONObject(index)
                val versionName = entry.getString("versionName")
                val versionCode = entry.getLong("versionCode")
                require(VERSION_NAME_PATTERN.matches(versionName)) {
                    "Invalid app changelog version name"
                }
                require(versionCode > 0) { "Invalid app changelog version code" }
                val notesObject = entry.getJSONObject("notes")
                val notes = REQUIRED_NOTE_LOCALES.associateWith { locale ->
                    parseNotes(notesObject.getJSONArray(locale), locale)
                }
                AppChangelogEntry(versionName, versionCode, notes)
            }.also { entries ->
                require(entries.map { it.versionCode }.distinct().size == entries.size) {
                    "App changelog contains duplicate versions"
                }
            }
        }

        private fun parseNotes(value: JSONArray, locale: String): List<String> {
            require(value.length() in 1..MAX_NOTES_PER_LOCALE) {
                "Invalid $locale app release note count"
            }
            return List(value.length()) { index ->
                value.getString(index).also { note ->
                    require(note.isNotBlank() && note.length <= MAX_NOTE_LENGTH) {
                        "Invalid $locale app release note"
                    }
                }
            }
        }

        private fun validateApkUrl(value: String) {
            val url = URL(value)
            require(url.protocol == "https") { "App updates require HTTPS" }
            require(url.host.equals("github.com", ignoreCase = true)) {
                "App update APK must be hosted on GitHub"
            }
            require(url.path.contains(RELEASE_PATH_SEGMENT) && url.path.endsWith(".apk")) {
                "Unexpected app update APK URL"
            }
            require(url.query == null && url.ref == null) { "Unexpected app update APK URL" }
        }

        private const val MAX_CHANGELOG_ENTRIES = 10
        private const val MAX_NOTES_PER_LOCALE = 12
        private const val MAX_NOTE_LENGTH = 240
        private val REQUIRED_NOTE_LOCALES = listOf("en", "pt", "ru")
    }
}
