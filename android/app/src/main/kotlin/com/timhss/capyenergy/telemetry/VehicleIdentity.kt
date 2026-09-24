package com.timhss.capyenergy.telemetry

import android.util.Log
import com.timhss.capyenergy.telemetry.db.RoomVehicleIdAliasStore
import java.io.File

/**
 * Where the current vehicle id came from, best first.
 *
 * Persisted alongside the id so a later boot knows whether the id is already
 * the VIN (nothing left to do) or a lesser anchor that a VIN read can upgrade.
 */
object VehicleIdAnchor {
    const val VIN = "vin"
    const val FILE = "file"
    const val ANDROID_ID = "android_id"
    const val OFFERED = "offered"
}

/**
 * Aliases from retired ids to the canonical one that replaced them.
 *
 * An upgrade records an alias rather than rewriting history: rows recorded
 * under the old id keep their `vehicle_id` and are resolved through this
 * store. [RoomVehicleIdAliasStore] is the production implementation.
 */
interface VehicleIdAliasStore {
    fun record(aliasId: String, canonicalId: String, atUtcMillis: Long)
    fun canonicalFor(aliasId: String): String?
}

/**
 * The identity file, written outside the app sandbox.
 *
 * The app shares the system UID (`android.uid.system` in the manifest), so a
 * file under the system data directory survives an uninstall that wipes the
 * app's own sandbox, its Room database and its SharedPreferences. After a
 * reinstall this file is the second anchor, before ANDROID_ID.
 *
 * Every operation is guarded: a failure only demotes the anchor, never breaks
 * the boot path that resolves the identity.
 */
class VehicleIdentityFile(private val pathProvider: () -> File?) {
    constructor(file: File?) : this({ file })

    fun read(): String? {
        val file = pathProvider() ?: return null
        return runCatching {
            if (!file.isFile) return null
            file.readText().trim().takeIf { it.isNotBlank() }
        }.onFailure { Log.w(TAG, "Could not read identity file", it) }
            .getOrNull()
    }

    fun write(id: String) {
        val file = pathProvider() ?: return
        runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(id)
            if (!tmp.renameTo(file)) {
                file.writeText(id)
                tmp.delete()
            }
        }.onFailure { Log.w(TAG, "Could not write identity file", it) }
    }

    private companion object {
        const val TAG = "VehicleIdentity"
    }
}

/** The production identity file location, writable because of the shared system UID. */
fun defaultIdentityFile(): VehicleIdentityFile = VehicleIdentityFile {
    // /data/system is owned by the system UID the app shares (android.uid.system);
    // it survives an uninstall that wipes the app sandbox.
    runCatching { File("/data/system", "capyenergy/vehicle_identity") }.getOrNull()
}
/**
 * Resolves the vehicle identity from layered anchors, best first:
 *
 * 1. the VIN, retried with backoff by [tryVinUpgrade] rather than abandoned
 *    after one failure — a VIN unreadable at boot and readable moments later
 *    still ends up as the identity;
 * 2. an identity file outside the app sandbox, which survives an uninstall;
 * 3. `Settings.Secure.ANDROID_ID`, scoped to the signing key and therefore
 *    stable across reinstall — this replaces the random UUID the old minter
 *    froze on the first VIN failure;
 * 4. the id offered by the phone at claim time, adopted only when the car
 *    holds no id at all and no session has been recorded.
 *
 * Identity must resolve before the first session is recorded. After that it
 * may only be upgraded (a synthetic id to the real VIN), never replaced, and
 * an upgrade writes an alias row rather than rewriting history. Until an id
 * resolves, callers keep the `unassigned` placeholder; the uploader already
 * skips unscoped rows and waits.
 */
class VehicleIdentityResolver(
    private val settings: TelemetrySettings,
    private val aliases: VehicleIdAliasStore,
    private val identityFile: VehicleIdentityFile?,
    private val vinReader: () -> String?,
    private val androidIdProvider: () -> String?,
    private val hasRecordedSessions: () -> Boolean,
    private val legacyVehicleIdsProvider: (() -> List<String>)? = null,
    private val nowUtcMillis: () -> Long = System::currentTimeMillis
) {

    /**
     * Establishes the best available identity without blocking on the car.
     *
     * Called before the first session of a boot can be recorded. Never mints
     * a random id: when every anchor fails it returns null and callers keep
     * `unassigned` until a later attempt resolves.
     */
    fun bootstrap(): String? {
        if (settings.vehicleIdAnchor() == VehicleIdAnchor.VIN) {
            resolveLegacyAliases()
            return settings.vehicleId()
        }

        if (settings.vehicleId().isNullOrBlank()) {
            identityFile?.read()?.let { id ->
                settings.setVehicleId(id)
                settings.setVehicleIdAnchor(VehicleIdAnchor.FILE)
                Log.i(TAG, "Adopted vehicle id from identity file")
            }
        }
        tryVinUpgrade()
        if (settings.vehicleId().isNullOrBlank()) {
            val androidId = runCatching { androidIdProvider() }.getOrNull()
                ?.trim()?.takeIf { it.isNotBlank() }
            if (androidId != null) {
                settings.setVehicleId(androidId)
                settings.setVehicleIdAnchor(VehicleIdAnchor.ANDROID_ID)
                Log.i(TAG, "Minted vehicle id from ANDROID_ID")
            }
        }
        // Mirror whatever id we ended with, so the next install finds it even
        // if the app sandbox is wiped in between.
        settings.vehicleId()?.let { identityFile?.write(it) }
        resolveLegacyAliases()
        return settings.vehicleId()
    }

    /**
     * Anchor 1: the VIN.
     *
     * Reads the VIN once per call; the caller retries with backoff while the
     * Car service is unavailable. On success the VIN becomes the id. A
     * synthetic id already in use is upgraded, not discarded: an alias row
     * records old → VIN and the identity file is refreshed, but no recorded
     * row is rewritten.
     */
    fun tryVinUpgrade(): String? {
        val vin = runCatching { vinReader() }.getOrNull()
            ?.trim()?.takeIf { it.isNotBlank() } ?: return null
        val current = settings.vehicleId()
        if (current == vin) {
            if (settings.vehicleIdAnchor() != VehicleIdAnchor.VIN) {
                // An install that happened to mint the VIN before anchors were
                // tracked; stamp the anchor without aliasing the id to itself.
                settings.setVehicleIdAnchor(VehicleIdAnchor.VIN)
            }
            return vin
        }
        if (!current.isNullOrBlank()) {
            aliases.record(aliasId = current, canonicalId = vin, atUtcMillis = nowUtcMillis())
            Log.i(TAG, "Upgraded vehicle id to VIN; alias recorded for the previous id")
        } else {
            Log.i(TAG, "Resolved vehicle id from VIN")
        }
        settings.setVehicleId(vin)
        settings.setVehicleIdAnchor(VehicleIdAnchor.VIN)
        identityFile?.write(vin)
        resolveLegacyAliases()
        return vin
    }

    /**
     * Anchor 4: the id the phone offers when it claims the car.
     *
     * Adopted only when the car holds no id at all and no session has been
     * recorded — a car with history must never take a new identity. Returns
     * the adopted id, or null when the offer is refused.
     */
    fun adoptOfferedId(offered: String?): String? {
        val id = offered?.trim()?.takeIf { it.isNotBlank() } ?: return null
        if (!settings.vehicleId().isNullOrBlank()) return null
        if (hasRecordedSessions()) return null
        settings.setVehicleId(id)
        settings.setVehicleIdAnchor(VehicleIdAnchor.OFFERED)
        identityFile?.write(id)
        Log.i(TAG, "Adopted vehicle id offered by the phone")
        resolveLegacyAliases()
        return id
    }

    /**
     * Discovers legacy vehicle IDs recorded before persistent anchors existed,
     * and maps each orphan ID as an alias to the current canonical ID.
     */
    fun resolveLegacyAliases() {
        val canonicalId = settings.vehicleId()?.trim()?.takeIf { it.isNotBlank() && it != "unassigned" } ?: return
        val legacyIds = runCatching { legacyVehicleIdsProvider?.invoke() }.getOrNull() ?: return
        for (legacyId in legacyIds) {
            val trimmed = legacyId.trim()
            if (trimmed.isNotBlank() && trimmed != "unassigned" && trimmed != canonicalId) {
                if (aliases.canonicalFor(trimmed) == null) {
                    aliases.record(aliasId = trimmed, canonicalId = canonicalId, atUtcMillis = nowUtcMillis())
                    Log.i(TAG, "Auto-aliased legacy vehicle id '$trimmed' to canonical '$canonicalId'")
                }
            }
        }
    }

    private companion object {
        const val TAG = "VehicleIdentity"
    }
}
