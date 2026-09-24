package com.timhss.capyenergy.walkaway

import android.util.Log
import com.timhss.capyenergy.concurrent.namedSingleThreadScheduledExecutor
import com.timhss.capyenergy.roadcast.RoadcastClient
import com.timhss.capyenergy.roadcast.RoadcastReading
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * FOB / RKE reader for walk-away lock.
 *
 * Dead code. Nothing constructs this. CollectionSequence and
 * TelemetryGraph must not start it.
 * The class stays so walk-away lock can take the same shape later.
 */
class KeySignalProvider {
    interface Listener {
        fun onKeyChanged(state: KeyState)
    }

    private val executor = namedSingleThreadScheduledExecutor("walkaway-key")
    private val listeners = CopyOnWriteArrayList<Listener>()

    @Volatile
    private var client: RoadcastClient? = null

    @Volatile
    private var tick: ScheduledFuture<*>? = null

    @Volatile
    private var lastError: String? = null

    @Volatile
    private var currentState: KeyState = DEFAULT_STATE

    private var indices: IntArray = intArrayOf()
    private var reading: RoadcastReading? = null

    private var previousDoors = BooleanArray(6) { false }
    private var previousFob = 0

    fun start() {
        if (tick != null) return
        tick = executor.scheduleAtFixedRate(
            { runCatching { pump() }.onFailure { lastError = it.message } },
            0L,
            TICK_INTERVAL_MILLIS,
            TimeUnit.MILLISECONDS
        )
    }

    @Synchronized
    fun stop() {
        tick?.cancel(false)
        tick = null
        disconnect()
    }

    @Synchronized
    fun disconnect() {
        client?.close()
        client = null
        indices = intArrayOf()
        reading = null
    }

    fun currentState(): KeyState = currentState

    fun addListener(listener: Listener) {
        listeners.add(listener)
    }

    fun removeListener(listener: Listener) {
        listeners.remove(listener)
    }

    fun statusMap(): Map<String, Any?> = mapOf(
        "attached" to (client != null),
        "signalCount" to indices.size,
        "lastError" to lastError,
        "state" to currentState.toMap(),
    )

    @Synchronized
    private fun pump() {
        val active = ensureClient() ?: return
        val currentIndices = indices
        if (currentIndices.isEmpty()) return

        val currentReading = reading ?: return
        val result = active.read(currentIndices, currentReading)
        if (result < 0) {
            lastError = "Roadcast read failed ($result)"
            return
        }

        val newState = parseReading(currentReading)
        lastError = null

        val changed = newState != currentState
        if (changed) {
            Log.d(TAG, "KeyState changed: $currentState -> $newState")
            currentState = newState
            notifyListeners(newState)
        }
    }

    private fun ensureClient(): RoadcastClient? {
        client?.let { return it }

        Log.d(TAG, "KeySignalProvider ensuring client connection...")
        val connected = RoadcastClient.connect().getOrElse { error ->
            lastError = "Roadcast client failed to connect: ${error.message}"
            Log.e(TAG, "KeySignalProvider connect failed: $lastError")
            return null
        }

        val resolvedIndices = SIGNAL_NAMES.map { name ->
            val index = connected.findSignal(name)
            if (index < 0) {
                Log.w(TAG, "Signal '$name' not found in Roadcast schema")
            } else {
                Log.d(TAG, "Signal '$name' -> index $index")
            }
            index
        }.toIntArray()

        val validIndices = resolvedIndices.filter { it >= 0 }.toIntArray()
        Log.d(TAG, "KeySignalProvider resolved ${validIndices.size}/${SIGNAL_NAMES.size} signals")
        if (validIndices.isEmpty()) {
            connected.close()
            lastError = "No key signals found in Roadcast schema"
            Log.e(TAG, lastError!!)
            return null
        }

        indices = validIndices
        reading = RoadcastReading(validIndices.size)
        client = connected
        lastError = null
        Log.i(TAG, "KeySignalProvider attached: ${validIndices.size} signals")
        return connected
    }

    private fun parseReading(reading: RoadcastReading): KeyState {
        var fobNum = 0
        var rkeCommand = 0
        val doors = BooleanArray(6) { false }

        for (i in indices.indices) {
            val raw = reading.rawAt(i).toInt()
            val name = SIGNAL_NAMES.getOrNull(i) ?: continue
            when (name) {
                SIGNAL_FOB_NUM -> fobNum = raw
                SIGNAL_RKE_COMMAND -> rkeCommand = raw
                SIGNAL_DOOR_FL -> doors[0] = raw >= 1
                SIGNAL_DOOR_FR -> doors[1] = raw >= 1
                SIGNAL_DOOR_RL -> doors[2] = raw >= 1
                SIGNAL_DOOR_RR -> doors[3] = raw >= 1
                SIGNAL_HOOD -> doors[4] = raw >= 1
                SIGNAL_TRUNK -> doors[5] = raw >= 1
            }
        }

        val fobDetection = detectFob(fobNum, doors)

        val newState = KeyState(
            fobDetected = fobDetection,
            rkeCommand = rkeCommand,
        )

        previousFob = fobNum
        previousDoors = doors

        return newState
    }

    private fun detectFob(fobNum: Int, doors: BooleanArray): FobDetection {
        val anyDoorJustClosed = doors.indices.any { i ->
            previousDoors[i] && !doors[i]
        }

        if (anyDoorJustClosed) {
            return if (fobNum >= 1) FobDetection.INSIDE else FobDetection.OUTSIDE
        }

        return currentState.fobDetected
    }

    private fun notifyListeners(state: KeyState) {
        for (listener in listeners) {
            listener.onKeyChanged(state)
        }
    }

    companion object {
        private const val TAG = "KeySignalProvider"
        private const val TICK_INTERVAL_MILLIS = 200L

        private const val SIGNAL_FOB_NUM = "PEPS_FOB_NUM"
        private const val SIGNAL_RKE_COMMAND = "PEPS_RKECommand"
        private const val SIGNAL_DOOR_FL = "BCM_FrontLeftDoorAjarStatus"
        private const val SIGNAL_DOOR_FR = "BCM_FrontRightDoorAjarStatus"
        private const val SIGNAL_DOOR_RL = "BCM_RearLeftDoorAjarStatus"
        private const val SIGNAL_DOOR_RR = "BCM_RearRightDoorAjarStatus"
        private const val SIGNAL_HOOD = "BCM_HoodAjarStatus"
        private const val SIGNAL_TRUNK = "BCM_TrunkAjarStatus"

        val RKE_FRUNK = 13
        val RKE_TRUNK = 2
        val RKE_UNLOCK = 3

        private val SIGNAL_NAMES = listOf(
            SIGNAL_FOB_NUM,
            SIGNAL_RKE_COMMAND,
            SIGNAL_DOOR_FL,
            SIGNAL_DOOR_FR,
            SIGNAL_DOOR_RL,
            SIGNAL_DOOR_RR,
            SIGNAL_HOOD,
            SIGNAL_TRUNK,
        )

        private val DEFAULT_STATE = KeyState(
            fobDetected = FobDetection.UNKNOWN,
            rkeCommand = 0,
        )
    }
}
