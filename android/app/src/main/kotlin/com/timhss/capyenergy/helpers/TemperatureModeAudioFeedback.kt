package com.timhss.capyenergy.helpers

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import java.util.concurrent.ExecutorService
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

interface TemperatureModeAudioFeedback {
    fun knobProgress(step: Int)
    fun modeActive()
    fun modeExit()
    fun temperatureChanged(tempC: Number?)
    fun fanSpeedChanged(speed: Number?)
    fun shutdown()
}

class AudioTrackTemperatureModeFeedback : TemperatureModeAudioFeedback {
    private val executor: ExecutorService = namedSingleThreadExecutor("helper-audio")

    override fun knobProgress(step: Int) {
        play(TemperatureModeAudioProfile.knobProgress(step))
    }

    override fun modeActive() {
        play(TemperatureModeAudioProfile.modeActive())
    }

    override fun modeExit() {
        play(TemperatureModeAudioProfile.modeExit())
    }

    override fun temperatureChanged(tempC: Number?) {
        play(TemperatureModeAudioProfile.temperatureChanged(tempC?.toFloat()))
    }

    override fun fanSpeedChanged(speed: Number?) {
        play(TemperatureModeAudioProfile.fanSpeedChanged(speed?.toInt()))
    }

    override fun shutdown() {
        executor.shutdownNow()
    }

    private fun play(cue: TemperatureModeAudioCue) {
        executor.execute {
            cue.tones.forEach { tone ->
                runCatching { playTone(tone) }
                    .onFailure { Log.w(TAG, "Failed to play helper audio cue", it) }
            }
        }
    }

    private fun playTone(tone: TemperatureModeAudioTone) {
        val samples = (SAMPLE_RATE * tone.durationMillis / 1_000L).coerceAtLeast(1L).toInt()
        val bytes = ByteArray(samples * BYTES_PER_SAMPLE)
        for (index in 0 until samples) {
            val progress = index.toFloat() / samples.toFloat()
            val envelope = when {
                progress < ATTACK_RATIO -> progress / ATTACK_RATIO
                progress > 1f - RELEASE_RATIO -> (1f - progress) / RELEASE_RATIO
                else -> 1f
            }.coerceIn(0f, 1f)
            val radians = 2.0 * PI * tone.frequencyHz * index / SAMPLE_RATE
            val secondary = tone.harmonicMix * sin(radians * 2.0)
            val wave = ((1f - tone.harmonicMix) * sin(radians) + secondary) * tone.gain * envelope
            val pcm = (wave.coerceIn(-1.0, 1.0) * Short.MAX_VALUE).roundToInt().toShort()
            bytes[index * 2] = (pcm.toInt() and 0xFF).toByte()
            bytes[index * 2 + 1] = ((pcm.toInt() shr 8) and 0xFF).toByte()
        }

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(bytes.size)
            .build()
        try {
            track.write(bytes, 0, bytes.size)
            track.play()
            Thread.sleep(tone.durationMillis + tone.pauseAfterMillis)
        } finally {
            runCatching { track.stop() }
            track.release()
        }
    }

    companion object {
        private const val TAG = "HelperAudioFeedback"
        private const val SAMPLE_RATE = 22_050
        private const val BYTES_PER_SAMPLE = 2
        private const val ATTACK_RATIO = 0.12f
        private const val RELEASE_RATIO = 0.18f
    }
}

object NoopTemperatureModeAudioFeedback : TemperatureModeAudioFeedback {
    override fun knobProgress(step: Int) = Unit
    override fun modeActive() = Unit
    override fun modeExit() = Unit
    override fun temperatureChanged(tempC: Number?) = Unit
    override fun fanSpeedChanged(speed: Number?) = Unit
    override fun shutdown() = Unit
}

object TemperatureModeAudioProfile {
    fun knobProgress(step: Int): TemperatureModeAudioCue {
        val cleanStep = step.coerceIn(1, 3)
        return TemperatureModeAudioCue(
            listOf(
                TemperatureModeAudioTone(
                    frequencyHz = 480 + cleanStep * 150,
                    durationMillis = 72,
                    gain = 0.16f,
                    pauseAfterMillis = 20
                )
            )
        )
    }

    fun modeActive(): TemperatureModeAudioCue = TemperatureModeAudioCue(
        listOf(
            TemperatureModeAudioTone(720, 70, 0.17f, pauseAfterMillis = 18),
            TemperatureModeAudioTone(940, 70, 0.17f, pauseAfterMillis = 18),
            TemperatureModeAudioTone(1_220, 115, 0.2f, pauseAfterMillis = 35)
        )
    )

    fun modeExit(): TemperatureModeAudioCue = TemperatureModeAudioCue(
        listOf(
            TemperatureModeAudioTone(760, 85, 0.15f, pauseAfterMillis = 20),
            TemperatureModeAudioTone(520, 130, 0.16f, pauseAfterMillis = 35)
        )
    )

    fun temperatureChanged(tempC: Float?): TemperatureModeAudioCue {
        val normalized = ((tempC ?: 22f) - 15.5f) / (28.5f - 15.5f)
        val frequency = 620 + (normalized.coerceIn(0f, 1f) * 560).roundToInt()
        return TemperatureModeAudioCue(
            listOf(
                TemperatureModeAudioTone(
                    frequencyHz = frequency,
                    durationMillis = 58,
                    gain = 0.13f,
                    pauseAfterMillis = 12
                ),
                TemperatureModeAudioTone(
                    frequencyHz = frequency + 80,
                    durationMillis = 42,
                    gain = 0.11f,
                    pauseAfterMillis = 20
                )
            )
        )
    }

    fun fanSpeedChanged(speed: Int?): TemperatureModeAudioCue {
        val cleanSpeed = (speed ?: 4).coerceIn(1, 9)
        val frequency = 260 + cleanSpeed * 58
        return TemperatureModeAudioCue(
            listOf(
                TemperatureModeAudioTone(
                    frequencyHz = frequency,
                    durationMillis = 82,
                    gain = 0.12f,
                    harmonicMix = 0.32f,
                    pauseAfterMillis = 14
                ),
                TemperatureModeAudioTone(
                    frequencyHz = frequency + 24,
                    durationMillis = 82,
                    gain = 0.1f,
                    harmonicMix = 0.38f,
                    pauseAfterMillis = 22
                )
            )
        )
    }
}

data class TemperatureModeAudioCue(
    val tones: List<TemperatureModeAudioTone>
)

data class TemperatureModeAudioTone(
    val frequencyHz: Int,
    val durationMillis: Long,
    val gain: Float,
    val harmonicMix: Float = 0f,
    val pauseAfterMillis: Long = 0L
)
