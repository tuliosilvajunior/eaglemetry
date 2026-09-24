package com.timhss.capyenergy.walkaway

import android.util.Log
import com.timhss.capyenergy.concurrent.namedSingleThreadScheduledExecutor
import com.timhss.capyenergy.roadcast.RoadcastClient
import com.timhss.capyenergy.roadcast.RoadcastReading
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Door / belt reader for walk-away lock.
 *
 * Dead code. Nothing constructs this. CollectionSequence and
 * TelemetryGraph must not start it.
 * The class stays so walk-away lock can take the same shape later.
 */
class OccupancySignalProvider {
    interface Listener {
        fun onOccupancyChanged(state: OccupancyState)
    }

    private val executor = namedSingleThreadScheduledExecutor("walkaway-occ")
    private val listeners = CopyOnWriteArrayList<Listener>()

    @Volatile
    private var client: RoadcastClient? = null

    @Volatile
    private var tick: ScheduledFuture<*>? = null

    @Volatile
    private var lastError: String? = null

    @Volatile
    private var currentState: OccupancyState = DEFAULT_STATE

    private var indices: IntArray = intArrayOf()
    private var reading: RoadcastReading? = null

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

    fun currentState(): OccupancyState = currentState

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

        val newState = parseReading(currentReading, currentIndices.size)
        lastError = null

        val changed = newState != currentState
        if (changed) {
            Log.d(TAG, "OccupancyState changed: $currentState -> $newState")
            currentState = newState
            notifyListeners(newState)
        }
    }

    private fun ensureClient(): RoadcastClient? {
        client?.let { return it }

        Log.d(TAG, "OccupancySignalProvider ensuring client connection...")
        val connected = RoadcastClient.connect().getOrElse { error ->
            lastError = "Roadcast client failed to connect: ${error.message}"
            Log.e(TAG, "OccupancySignalProvider connect failed: $lastError")
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
        Log.d(
            TAG,
            "OccupancySignalProvider resolved ${validIndices.size}/${SIGNAL_NAMES.size} signals"
        )
        if (validIndices.isEmpty()) {
            connected.close()
            lastError = "No occupancy signals found in Roadcast schema"
            Log.e(TAG, lastError!!)
            return null
        }

        indices = validIndices
        reading = RoadcastReading(validIndices.size)
        client = connected
        lastError = null
        Log.i(TAG, "OccupancySignalProvider attached: ${validIndices.size} signals")
        return connected
    }

    private fun parseReading(reading: RoadcastReading, count: Int): OccupancyState {
        val values = BooleanArray(8) { false }
        for (i in 0 until minOf(count, 8)) {
            values[i] = reading.valueAt(i) >= 1.0
        }
        val seatbeltOffset = DOOR_SIGNAL_COUNT
        val driverBuckled = if (count > seatbeltOffset) {
            reading.valueAt(seatbeltOffset) >= 1.0
        } else {
            false
        }
        val passengerBuckled = if (count > seatbeltOffset + 1) {
            reading.valueAt(seatbeltOffset + 1) < 1.0
        } else {
            false
        }

        return OccupancyState(
            doorFrontLeftOpen = values[0],
            doorFrontRightOpen = values[1],
            doorRearLeftOpen = values[2],
            doorRearRightOpen = values[3],
            hoodOpen = values[4],
            trunkOpen = values[5],
            driverSeatbeltBuckled = driverBuckled,
            passengerSeatbeltBuckled = passengerBuckled,
        )
    }

    private fun notifyListeners(state: OccupancyState) {
        for (listener in listeners) {
            listener.onOccupancyChanged(state)
        }
    }

    companion object {
        private const val TAG = "OccupancySignalProvider"
        private const val TICK_INTERVAL_MILLIS = 200L
        private const val DOOR_SIGNAL_COUNT = 6

        private val SIGNAL_NAMES = listOf(
            "BCM_FrontLeftDoorAjarStatus",
            "BCM_FrontRightDoorAjarStatus",
            "BCM_RearLeftDoorAjarStatus",
            "BCM_RearRightDoorAjarStatus",
            "BCM_HoodAjarStatus",
            "BCM_TrunkAjarStatus",
            "ACU_DrvSeatbeltBucklestatus",
            "ACU_PassSeatbeltWarning",
        )

        private val DEFAULT_STATE = OccupancyState(
            doorFrontLeftOpen = false,
            doorFrontRightOpen = false,
            doorRearLeftOpen = false,
            doorRearRightOpen = false,
            hoodOpen = false,
            trunkOpen = false,
            driverSeatbeltBuckled = false,
            passengerSeatbeltBuckled = false,
        )
    }
}
