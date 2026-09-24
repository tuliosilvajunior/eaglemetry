package com.timhss.capyenergy.telemetry

import android.os.SystemClock
import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.RawReading
import com.timhss.capyenergy.profile.SignalSpec
import com.timhss.capyenergy.profile.VehicleProfile

/**
 * A raw property read, turned into a sample in the canonical unit.
 *
 * The **scale, the band and the refusals** belong to the vehicle and are read
 * from [profile]. What stays here is the part that is the same on every
 * vehicle: when a value counts as measured, what a failed read looks like, and
 * how a timestamp is judged.
 *
 * The class used to carry a 90-branch `when` over every signal, which mixed the
 * two. A second vehicle had to edit it, and the exhaustive `when` was doing the
 * work a declaration does better
 */
class SignalNormalizer(private val profile: VehicleProfile = GeelyProfile) {

    fun normalize(
        spec: SignalSpec,
        rawValue: Any?,
        rawSource: SignalSource,
        propertyId: Int,
        sourceTimestampNanos: Long?,
        uncertaintyMillis: Long,
        details: String = ""
    ): SignalSample {
        val timestamp = signalTimestamp(rawSource, sourceTimestampNanos, uncertaintyMillis)
        val declaration = profile.declarationFor(spec.signalId)
        val normalized = declaration?.normalize(RawReading(rawValue, sourceTimestampNanos))

        return SignalSample(
            signalId = spec.signalId,
            value = normalized,
            unit = spec.signalId.unit,
            quality = if (normalized == null) SignalQuality.UNAVAILABLE else SignalQuality.MEASURED,
            source = rawSource,
            propertyId = propertyId,
            propertyIdHex = propertyId.toHexPropertyId(),
            areaId = spec.areaId,
            timestamp = timestamp,
            details = details
        )
    }

    fun errorSample(
        spec: SignalSpec,
        propertyId: Int,
        source: SignalSource,
        uncertaintyMillis: Long,
        error: Throwable
    ): SignalSample {
        return SignalSample(
            signalId = spec.signalId,
            value = null,
            unit = spec.signalId.unit,
            quality = SignalQuality.ERROR,
            source = source,
            propertyId = propertyId,
            propertyIdHex = propertyId.toHexPropertyId(),
            areaId = spec.areaId,
            timestamp = signalTimestamp(source, null, uncertaintyMillis),
            details = shortError(error)
        )
    }

    private fun signalTimestamp(
        source: SignalSource,
        sourceTimestampNanos: Long?,
        uncertaintyMillis: Long
    ): SignalTimestamp {
        val cleanSourceTimestamp = sourceTimestampNanos?.takeIf { it > 0L }
        val accuracy = when {
            // PROP_RAM lê um snapshot em cadência fixa, como o polling: o
            // carimbo do VHAL diz quando o valor foi publicado, não quando o
            // vimos, e é a segunda coisa que a incerteza descreve.
            source == SignalSource.VHAL_POLLING || source == SignalSource.PROP_RAM ->
                TimestampAccuracy.POLLED
            cleanSourceTimestamp != null -> TimestampAccuracy.SOURCE_EVENT
            else -> TimestampAccuracy.RECEIVED_EVENT
        }
        return SignalTimestamp(
            receivedAtUtcMillis = System.currentTimeMillis(),
            receivedAtElapsedNanos = SystemClock.elapsedRealtimeNanos(),
            sourceTimestampNanos = cleanSourceTimestamp,
            accuracy = accuracy,
            uncertaintyMillis = if (accuracy == TimestampAccuracy.POLLED) uncertaintyMillis else 0L
        )
    }

    private fun shortError(throwable: Throwable): String {
        var root = throwable
        while (root.cause != null) root = root.cause!!
        val message = root.message
        return if (message.isNullOrBlank()) root::class.java.simpleName else "${root::class.java.simpleName}: $message"
    }
}
