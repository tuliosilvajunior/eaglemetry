package com.timhss.capyenergy.telemetry

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * One position fix.
 *
 * [bearingDeg] is the course over ground. It is absent while the vehicle is
 * stopped, because the receiver derives it from movement. The defaults let a
 * caller that only reconstructs a stored position build one without inventing
 * a course it never recorded.
 */
data class LocationSnapshot(
    val latitude: Double,
    val longitude: Double,
    val altitudeM: Double?,
    val accuracyM: Float?,
    val provider: String?,
    val elapsedRealtimeNanos: Long,
    val wallTimeUtcMillis: Long,
    val bearingDeg: Float? = null,
    val bearingAccuracyDeg: Float? = null,
    val speedMps: Float? = null
)

class LocationSignalProvider(context: Context) {
    private val appContext = context.applicationContext
    private val locationManager =
        appContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    @Volatile
    private var running = false

    @Volatile
    private var lastLocation: Location? = null

    @Volatile
    private var lastError: String? = null

    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            lastLocation = location
            lastError = null
            onFixReceived(location.time, location.elapsedRealtimeNanos)
        }

        @Deprecated("Deprecated in Android API")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit

        override fun onProviderEnabled(provider: String) = Unit

        override fun onProviderDisabled(provider: String) {
            lastError = "provider_disabled:$provider"
        }
    }

    /**
     * Offers one GPS fix `(wall, elapsed)` pair to the anchor store. Split
     * out so JVM tests prove the pair wiring without an Android `Location`:
     * the receiver's own clock (`location.time`) is the truth, the fix's
     * `elapsedRealtimeNanos` the monotonic mark beside it. A fix without
     * either half is useless and dropped — the store enforces the same.
     */
    internal fun onFixReceived(wallTimeUtcMillis: Long, elapsedRealtimeNanos: Long) {
        if (wallTimeUtcMillis <= 0L || elapsedRealtimeNanos <= 0L) return
        ClockAnchorStore.offerGpsFix(wallTimeUtcMillis, elapsedRealtimeNanos)
    }

    fun start() {
        if (running) return
        if (!hasLocationPermission()) {
            lastError = "permission_missing"
            return
        }
        val manager = locationManager
        if (manager == null) {
            lastError = "location_manager_unavailable"
            return
        }
        val provider = preferredProvider(manager)
        if (provider == null) {
            lastError = "provider_disabled"
            return
        }
        runCatching {
            manager.requestLocationUpdates(
                provider,
                LOCATION_INTERVAL_MILLIS,
                LOCATION_MIN_DISTANCE_METERS,
                listener,
                Looper.getMainLooper()
            )
            lastLocation = manager.getLastKnownLocation(provider) ?: lastLocation
            running = true
            lastError = null
        }.onFailure { error ->
            lastError = error.message ?: error::class.java.simpleName
            Log.w(TAG, "Failed to start location updates", error)
        }
    }

    fun stop() {
        if (!running) return
        runCatching {
            locationManager?.removeUpdates(listener)
        }.onFailure { error ->
            Log.w(TAG, "Failed to stop location updates", error)
        }
        running = false
    }

    fun latestSnapshot(maxAgeMillis: Long = LOCATION_MAX_AGE_MILLIS): LocationSnapshot? {
        val location = lastLocation ?: return null
        val ageMillis = ((SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000L)
            .coerceAtLeast(0L)
        if (ageMillis > maxAgeMillis) return null
        return LocationSnapshot(
            latitude = location.latitude,
            longitude = location.longitude,
            altitudeM = if (location.hasAltitude()) location.altitude else null,
            accuracyM = if (location.hasAccuracy()) location.accuracy else null,
            provider = location.provider,
            elapsedRealtimeNanos = location.elapsedRealtimeNanos,
            wallTimeUtcMillis = location.time,
            bearingDeg = if (location.hasBearing()) location.bearing else null,
            bearingAccuracyDeg = if (location.hasBearingAccuracy()) {
                location.bearingAccuracyDegrees
            } else {
                null
            },
            speedMps = if (location.hasSpeed()) location.speed else null
        )
    }

    /**
     * The course over ground, with the reason when there is none.
     *
     * [gpsEnabled] is the app setting, which this object does not own: when it
     * is off, nothing calls [start], and a silent provider would otherwise be
     * reported as a receiver that cannot see the sky.
     *
     * The age limit is the same one [latestSnapshot] applies, so a heading and
     * a position never disagree about whether the fix is still current.
     */
    fun heading(gpsEnabled: Boolean): VehicleHeading {
        val location = lastLocation
        val ageMillis = location?.let {
            ((SystemClock.elapsedRealtimeNanos() - it.elapsedRealtimeNanos) / 1_000_000L)
                .coerceAtLeast(0L)
        }
        return VehicleHeading.resolve(
            timestampMillis = System.currentTimeMillis(),
            gpsEnabled = gpsEnabled,
            permissionGranted = hasLocationPermission(),
            hasFix = location != null,
            fixAgeMillis = ageMillis,
            maxFixAgeMillis = LOCATION_MAX_AGE_MILLIS,
            bearingDeg = if (location?.hasBearing() == true) {
                location.bearing.toDouble()
            } else {
                null
            },
            bearingAccuracyDeg = if (location?.hasBearingAccuracy() == true) {
                location.bearingAccuracyDegrees.toDouble()
            } else {
                null
            },
            speedMps = if (location?.hasSpeed() == true) {
                location.speed.toDouble()
            } else {
                null
            }
        )
    }

    fun statusMap(): Map<String, Any?> {
        val location = lastLocation
        val ageMillis = location?.let {
            ((SystemClock.elapsedRealtimeNanos() - it.elapsedRealtimeNanos) / 1_000_000L)
                .coerceAtLeast(0L)
        }
        return mapOf(
            "running" to running,
            "permissionGranted" to hasLocationPermission(),
            "gpsProviderEnabled" to isProviderEnabled(LocationManager.GPS_PROVIDER),
            "networkProviderEnabled" to isProviderEnabled(LocationManager.NETWORK_PROVIDER),
            "lastError" to lastError,
            "lastFixAgeMillis" to ageMillis,
            "latitude" to location?.latitude,
            "longitude" to location?.longitude,
            "altitudeM" to if (location?.hasAltitude() == true) location.altitude else null,
            "gpsAccuracyM" to if (location?.hasAccuracy() == true) location.accuracy else null,
            "locationProvider" to location?.provider,
            "locationElapsedRealtimeNanos" to location?.elapsedRealtimeNanos,
            "bearingDeg" to if (location?.hasBearing() == true) location.bearing else null,
            "bearingAccuracyDeg" to if (location?.hasBearingAccuracy() == true) {
                location.bearingAccuracyDegrees
            } else {
                null
            },
            "speedMps" to if (location?.hasSpeed() == true) location.speed else null
        )
    }

    private fun hasLocationPermission(): Boolean {
        return appContext.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            appContext.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun preferredProvider(manager: LocationManager): String? {
        return when {
            isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            else -> manager.getProviders(true).firstOrNull()
        }
    }

    private fun isProviderEnabled(provider: String): Boolean {
        return runCatching {
            locationManager?.isProviderEnabled(provider) == true
        }.getOrDefault(false)
    }

    companion object {
        private const val TAG = "LocationSignalProvider"
        private const val LOCATION_INTERVAL_MILLIS = 1_000L
        private const val LOCATION_MIN_DISTANCE_METERS = 0f
        private const val LOCATION_MAX_AGE_MILLIS = 10_000L
    }
}
