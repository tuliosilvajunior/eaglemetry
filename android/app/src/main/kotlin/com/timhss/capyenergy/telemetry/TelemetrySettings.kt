package com.timhss.capyenergy.telemetry

import android.content.Context
import com.timhss.capyenergy.profile.GeelyProfile

class TelemetrySettings(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun vehicleId(): String? = prefs.getString(KEY_VEHICLE_ID, null)

    fun isVehicleIdMinted(): Boolean = !prefs.getString(KEY_VEHICLE_ID, null).isNullOrBlank()

    fun setVehicleId(value: String?) {
        prefs.edit().apply {
            if (value.isNullOrBlank()) {
                remove(KEY_VEHICLE_ID)
            } else {
                putString(KEY_VEHICLE_ID, value)
            }
        }.apply()
    }

    /**
     * Where the current vehicle id came from, one of [VehicleIdAnchor].
     * Absent on installs that minted before anchors were tracked.
     */
    fun vehicleIdAnchor(): String? = prefs.getString(KEY_VEHICLE_ID_ANCHOR, null)

    fun setVehicleIdAnchor(value: String?) {
        prefs.edit().apply {
            if (value.isNullOrBlank()) {
                remove(KEY_VEHICLE_ID_ANCHOR)
            } else {
                putString(KEY_VEHICLE_ID_ANCHOR, value)
            }
        }.apply()
    }

    fun autoStartOnBoot(): Boolean = prefs.getBoolean(KEY_AUTO_START_ON_BOOT, true)

    fun gpsEnabled(): Boolean = prefs.getBoolean(KEY_GPS_ENABLED, false)

    /**
     * The reader has asked that the car radio stay on for the companion.
     *
     * The BLE live stream dies with the adapter, and the head unit switches
     * the radio off on its own. This setting lets the app switch it back on.
     * Default off: an app does not take a car radio without being told to.
     */
    fun keepBluetoothOnEnabled(): Boolean = prefs.getBoolean(KEY_KEEP_BLUETOOTH_ON, false)

    fun debugEventFileEnabled(): Boolean = prefs.getBoolean(KEY_DEBUG_EVENT_FILE_ENABLED, false)

    fun temperatureModeHelperEnabled(): Boolean = prefs.getBoolean(KEY_TEMPERATURE_MODE_HELPER_ENABLED, false)

    fun replaceOemChargingEnabled(): Boolean = prefs.getBoolean(KEY_REPLACE_OEM_CHARGING_ENABLED, false)

    fun projectionBetaEnabled(): Boolean = prefs.getBoolean(KEY_PROJECTION_BETA_ENABLED, false)

    /**
     * Opt-in CONTINUOUS recording: one wall-clock-aligned minute for every
     * minute the car is awake, gated on nothing.
     *
     * Off by default. With it off the app is unchanged, byte for byte, from
     * what it was before this mode existed.
     */
    fun continuousModeEnabled(): Boolean = prefs.getBoolean(KEY_CONTINUOUS_MODE_ENABLED, false)

    fun defaultChargeCostPerKwh(): Double? {
        if (!prefs.contains(KEY_DEFAULT_CHARGE_COST_PER_KWH)) return null
        val value = prefs.getFloat(KEY_DEFAULT_CHARGE_COST_PER_KWH, Float.NaN).toDouble()
        return if (value.isFinite() && value >= 0.0) value else null
    }

    /**
     * Pack capacity in Wh, from the reader.
     *
     * This is the only capacity the app has. It always answers, because every
     * energy figure needs one and the car publishes none that can be believed;
     * an unset setting means the default pack, not an unknown pack.
     */
    fun packCapacityWh(): Double {
        val value = prefs.getFloat(KEY_PACK_CAPACITY_WH, Float.NaN).toDouble()
        return if (value.isFinite() && value in GeelyProfile.battery.acceptedCapacityWh) {
            value
        } else {
            GeelyProfile.battery.defaultCapacityWh
        }
    }

    fun chargeCostCurrency(): String = prefs.getString(KEY_CHARGE_COST_CURRENCY, DEFAULT_CURRENCY) ?: DEFAULT_CURRENCY

    fun setChargeCostCurrency(value: String?) {
        prefs.edit().apply {
            val trimmed = value?.trim()?.takeIf { it.isNotEmpty() }
            if (trimmed == null) {
                remove(KEY_CHARGE_COST_CURRENCY)
            } else {
                putString(KEY_CHARGE_COST_CURRENCY, trimmed)
            }
        }.apply()
    }

    fun setAutoStartOnBoot(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_AUTO_START_ON_BOOT, enabled).apply()
    }

    fun setKeepBluetoothOnEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_KEEP_BLUETOOTH_ON, enabled).apply()
    }

    fun setGpsEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_GPS_ENABLED, enabled).apply()
    }

    fun setDebugEventFileEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_DEBUG_EVENT_FILE_ENABLED, enabled).apply()
    }

    fun setTemperatureModeHelperEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_TEMPERATURE_MODE_HELPER_ENABLED, enabled).apply()
    }

    fun setReplaceOemChargingEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_REPLACE_OEM_CHARGING_ENABLED, enabled).apply()
    }

    fun setProjectionBetaEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_PROJECTION_BETA_ENABLED, enabled).apply()
    }

    fun setContinuousModeEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_CONTINUOUS_MODE_ENABLED, enabled).apply()
    }

    fun setDefaultChargeCostPerKwh(value: Double?) {
        prefs.edit().apply {
            if (value == null || !value.isFinite() || value < 0.0) {
                remove(KEY_DEFAULT_CHARGE_COST_PER_KWH)
            } else {
                putFloat(KEY_DEFAULT_CHARGE_COST_PER_KWH, value.toFloat())
            }
        }.apply()
    }

    fun externalChargeControlEnabled(): Boolean = prefs.getBoolean(KEY_EXTERNAL_CHARGE_CONTROL_ENABLED, false)

    fun setExternalChargeControlEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_EXTERNAL_CHARGE_CONTROL_ENABLED, enabled).apply()
    }

    fun pairingStatus(): String = prefs.getString(KEY_PAIRING_STATUS, PAIRING_STATUS_UNPAIRED) ?: PAIRING_STATUS_UNPAIRED

    fun setPairingStatus(value: String?) {
        prefs.edit().apply {
            val normalized = value?.trim()?.takeIf { it.isNotEmpty() } ?: PAIRING_STATUS_UNPAIRED
            val safe = when (normalized) {
                PAIRING_STATUS_UNPAIRED, PAIRING_STATUS_PENDING, PAIRING_STATUS_APPROVED,
                PAIRING_STATUS_REGISTERED, PAIRING_STATUS_REVOKED -> normalized
                else -> PAIRING_STATUS_UNPAIRED
            }
            putString(KEY_PAIRING_STATUS, safe)
        }.apply()
    }

    fun carToken(): String? = prefs.getString(KEY_CAR_TOKEN, null)?.takeIf { it.isNotBlank() }

    fun setCarToken(value: String?) {
        prefs.edit().apply {
            if (value.isNullOrBlank()) {
                remove(KEY_CAR_TOKEN)
            } else {
                putString(KEY_CAR_TOKEN, value)
            }
        }.apply()
    }

    fun accountId(): String? = prefs.getString(KEY_ACCOUNT_ID, null)?.takeIf { it.isNotBlank() }

    fun setAccountId(value: String?) {
        prefs.edit().apply {
            if (value.isNullOrBlank()) {
                remove(KEY_ACCOUNT_ID)
            } else {
                putString(KEY_ACCOUNT_ID, value)
            }
        }.apply()
    }

    /**
     * The vehicle id the current [carToken] was registered under.
     *
     * When the identity later upgrades (android_id → VIN) this is what the
     * boot re-key check compares against: a mismatch means the token is bound
     * to a retired id and RLS would refuse every upload, so registration is
     * re-run under the canonical id. Absent on installs that registered
     * before this field existed — the mismatch check then re-registers too,
     * which is the recovery path for already-stranded cars.
     */
    fun registeredVehicleId(): String? = prefs.getString(KEY_REGISTERED_VEHICLE_ID, null)

    fun registeredAtUtcMillis(): Long? =
        prefs.getString(KEY_REGISTERED_AT_UTC_MILLIS_KEY, null)?.toLongOrNull()

    /** Clear the boot-registration credential; returns to unpaired. */
    fun resetRegistration() {
        prefs.edit().apply {
            putString(KEY_PAIRING_STATUS, PAIRING_STATUS_UNPAIRED)
            remove(KEY_CAR_TOKEN)
            remove(KEY_REGISTERED_VEHICLE_ID)
            remove(KEY_REGISTERED_AT_UTC_MILLIS_KEY)
        }.apply()
    }


    /**
     * Stores the pre-claim registration credential in one atomic write.
     *
     * Three fields change together — token, the vehicle id it was minted
     * under, and the status. A crash between three separate `apply()` calls
     * would leave a persisted token with status `unpaired`, which shuts the
     * upload gate forever (every boot sees a token and skips re-registration,
     * but the gate keys on status). One `apply()` makes the state
     * all-or-nothing.
     */
    fun register(token: String, vehicleId: String, atUtcMillis: Long = System.currentTimeMillis()) {
        prefs.edit().apply {
            putString(KEY_CAR_TOKEN, token)
            putString(KEY_REGISTERED_VEHICLE_ID, vehicleId)
            putString(KEY_REGISTERED_AT_UTC_MILLIS_KEY, atUtcMillis.toString())
            putString(KEY_PAIRING_STATUS, PAIRING_STATUS_REGISTERED)
            remove(KEY_ACCOUNT_ID)
        }.apply()
    }

    /**
     * Marks the pairing as revoked.
     *
     * Flips pairing status to [PAIRING_STATUS_REVOKED]. Intentionally retains
     * car_token and account_id so the UI knows previous pairing context and
     * can prompt re-pairing with "NEW CODE", and so cutover readiness attempts
     * can address the vehicle/account row. Upload gating strictly checks status
     * against REGISTERED/APPROVED, preventing retry storms with a dead token.
     */
    fun markRevoked() {
        prefs.edit().putString(KEY_PAIRING_STATUS, PAIRING_STATUS_REVOKED).apply()
    }

    fun clearPairing() {
        prefs.edit().apply {
            putString(KEY_PAIRING_STATUS, PAIRING_STATUS_UNPAIRED)
            remove(KEY_CAR_TOKEN)
            remove(KEY_ACCOUNT_ID)
        }.apply()
    }

    fun chargeTargetSocPercent(): Int = prefs.getInt(KEY_CHARGE_TARGET_SOC, 80).coerceIn(50, 100)

    fun setChargeTargetSocPercent(percent: Int) {
        prefs.edit().putInt(KEY_CHARGE_TARGET_SOC, percent.coerceIn(50, 100)).apply()
    }

    /** A null, or a value outside the band, restores the default pack. */
    fun setPackCapacityWh(value: Double?) {
        prefs.edit().apply {
            if (value == null || !value.isFinite() || value !in GeelyProfile.battery.acceptedCapacityWh) {
                remove(KEY_PACK_CAPACITY_WH)
            } else {
                putFloat(KEY_PACK_CAPACITY_WH, value.toFloat())
            }
        }.apply()
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "vehicleId" to vehicleId(),
        "autoStartOnBoot" to autoStartOnBoot(),
        "gpsEnabled" to gpsEnabled(),
        "keepBluetoothOnEnabled" to keepBluetoothOnEnabled(),
        "debugEventFileEnabled" to debugEventFileEnabled(),
        "temperatureModeHelperEnabled" to temperatureModeHelperEnabled(),
        "replaceOemChargingEnabled" to replaceOemChargingEnabled(),
        "externalChargeControlEnabled" to externalChargeControlEnabled(),
        "chargeTargetSoc" to chargeTargetSocPercent(),
        "projectionBetaEnabled" to projectionBetaEnabled(),
        "continuousModeEnabled" to continuousModeEnabled(),
        "defaultChargeCostPerKwh" to defaultChargeCostPerKwh(),
        "packCapacityWh" to packCapacityWh(),
        "chargeCostCurrency" to chargeCostCurrency(),
    )

    companion object {
        private const val PREFS_NAME = "telemetry_settings"
        private const val KEY_VEHICLE_ID = "vehicle_id"
        const val PAIRING_STATUS_UNPAIRED = "unpaired"
        const val PAIRING_STATUS_PENDING = "pending"
        const val PAIRING_STATUS_APPROVED = "approved"
        const val PAIRING_STATUS_REGISTERED = "registered"
        const val PAIRING_STATUS_REVOKED = "revoked"
        private const val KEY_PAIRING_STATUS = "pairing_status"
        private const val KEY_CAR_TOKEN = "car_token"
        private const val KEY_ACCOUNT_ID = "account_id"
        private const val KEY_AUTO_START_ON_BOOT = "auto_start_on_boot"
        private const val KEY_REGISTERED_AT_UTC_MILLIS_KEY = "registered_at_utc_millis"
        private const val KEY_REGISTERED_VEHICLE_ID = "registered_vehicle_id"
        private const val KEY_GPS_ENABLED = "gps_enabled"
        private const val KEY_KEEP_BLUETOOTH_ON = "keep_bluetooth_on"
        private const val KEY_DEBUG_EVENT_FILE_ENABLED = "debug_event_file_enabled"
        private const val KEY_TEMPERATURE_MODE_HELPER_ENABLED = "temperature_mode_helper_enabled"
        private const val KEY_REPLACE_OEM_CHARGING_ENABLED = "replace_oem_charging_enabled"
        private const val KEY_EXTERNAL_CHARGE_CONTROL_ENABLED = "external_charge_control_enabled"
        private const val KEY_CHARGE_TARGET_SOC = "charge_target_soc"
        private const val KEY_PROJECTION_BETA_ENABLED = "projection_beta_enabled"
        private const val KEY_CONTINUOUS_MODE_ENABLED = "continuous_mode_enabled"
        private const val KEY_DEFAULT_CHARGE_COST_PER_KWH = "default_charge_cost_per_kwh"
        private const val KEY_CHARGE_COST_CURRENCY = "charge_cost_currency"
        private const val KEY_VEHICLE_ID_ANCHOR = "vehicle_id_anchor"
        private const val KEY_PACK_CAPACITY_WH = "pack_capacity_wh"
        private const val DEFAULT_CURRENCY = "BRL"
    }
}
