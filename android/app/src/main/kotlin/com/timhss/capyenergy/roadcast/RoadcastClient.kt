package com.timhss.capyenergy.roadcast

internal object RoadcastNative {
    const val FLAG_VALID = 0x01
    const val FLAG_CALIBRATED = 0x02

    @Volatile
    private var loaded = false

    @Volatile
    private var loadError: String? = null

    @Synchronized
    fun ensureLoaded(): Boolean {
        if (loaded) return true
        if (loadError != null) return false
        return runCatching {
            System.loadLibrary("roadcast_jni")
            loaded = true
            true
        }.getOrElse { error ->
            loadError = error.message ?: error::class.java.simpleName
            false
        }
    }

    fun loadError(): String? = loadError

    @JvmStatic external fun nativeConnect(socketName: String, error: IntArray): Long
    @JvmStatic external fun nativeClose(handle: Long)
    @JvmStatic external fun nativeStatus(handle: Long, output: LongArray): Int
    @JvmStatic external fun nativeFindSignal(handle: Long, name: String): Int
    @JvmStatic external fun nativeSchemaEntry(
        handle: Long,
        index: Int,
        integers: LongArray,
        decimals: DoubleArray
    ): Array<String>?
    @JvmStatic external fun nativeSampleAgeNs(handle: Long): Long

    @JvmStatic external fun nativeReadSignals(
        handle: Long,
        indices: IntArray,
        physical: DoubleArray,
        raw: LongArray,
        lastChangeNs: LongArray,
        flags: ByteArray
    ): Int

    @JvmStatic external fun nativeErrorString(error: Int): String
}

data class RoadcastClientStatus(
    val hz: Int,
    val frameCount: Int,
    val signalCount: Int,
    val schemaVersion: Int,
    val schemaHash: Long,
    val sampleSequence: Long,
    val droppedBatches: Long,
    val coalescedSamples: Long,
    val resynchronizations: Long,
    val effectiveHzMillihz: Int,
    val sourceState: Int,
    val connected: Boolean
)

data class RoadcastSchemaEntry(
    val stableId: Long,
    val index: Int,
    val invalidSignalIndex: Int?,
    val canId: Int,
    val kind: Int,
    val source: Int,
    val width: Int,
    val flags: Int,
    val scale: Double,
    val offset: Double,
    val name: String,
    val unit: String
) {
    val signed: Boolean
        get() = flags and FLAG_SIGNED != 0

    val calibrated: Boolean
        get() = flags and FLAG_CALIBRATED != 0

    private companion object {
        const val FLAG_SIGNED = 0x01
        const val FLAG_CALIBRATED = 0x02
    }
}

class RoadcastReading internal constructor(size: Int) {
    internal val physical = DoubleArray(size)
    internal val raw = LongArray(size)
    internal val lastChangeNs = LongArray(size)
    internal val flags = ByteArray(size)

    fun valueAt(index: Int): Double = physical[index]
    fun rawAt(index: Int): Long = raw[index]
    fun lastChangeNsAt(index: Int): Long = lastChangeNs[index]
    fun isValidAt(index: Int): Boolean =
        flags[index].toInt() and RoadcastNative.FLAG_VALID != 0

    fun isCalibratedAt(index: Int): Boolean =
        flags[index].toInt() and RoadcastNative.FLAG_CALIBRATED != 0
}

/**
 * Read-only Roadcast connection used by [RoadcastRepository].
 *
 * The seam keeps repository tests independent from JNI and makes the repository
 * the only Kotlin owner of connection lifecycle and schema negotiation.
 */
interface RoadcastSession {
    fun status(): RoadcastClientStatus?
    fun schema(): List<RoadcastSchemaEntry>
    fun sampleAgeNs(): Long
    fun isAlive(maxAgeMs: Long = 500L): Boolean
    fun read(indices: IntArray, output: RoadcastReading): Int
    fun close()
}

class RoadcastClient private constructor(private var handle: Long) : RoadcastSession {
    private val statusBuffer = LongArray(14)
    private val schemaIntegerBuffer = LongArray(8)
    private val schemaDecimalBuffer = DoubleArray(2)

    override fun status(): RoadcastClientStatus? {
        if (handle == 0L || RoadcastNative.nativeStatus(handle, statusBuffer) < 0) return null
        return RoadcastClientStatus(
            hz = statusBuffer[0].toInt(),
            frameCount = statusBuffer[1].toInt(),
            signalCount = statusBuffer[2].toInt(),
            schemaVersion = statusBuffer[3].toInt(),
            schemaHash = statusBuffer[4],
            sampleSequence = statusBuffer[5],
            droppedBatches = statusBuffer[8],
            coalescedSamples = statusBuffer[9],
            resynchronizations = statusBuffer[10],
            effectiveHzMillihz = statusBuffer[11].toInt(),
            sourceState = statusBuffer[12].toInt(),
            connected = statusBuffer[13] != 0L
        )
    }

    fun findSignal(name: String): Int =
        if (handle == 0L) -1
        else RoadcastNative.nativeFindSignal(handle, name)

    fun schemaEntryAt(index: Int): RoadcastSchemaEntry? {
        if (handle == 0L || index < 0) return null
        val strings = RoadcastNative.nativeSchemaEntry(
            handle,
            index,
            schemaIntegerBuffer,
            schemaDecimalBuffer
        ) ?: return null
        if (strings.size < 2) return null
        return RoadcastSchemaEntry(
            stableId = schemaIntegerBuffer[0],
            index = schemaIntegerBuffer[1].toInt(),
            invalidSignalIndex = schemaIntegerBuffer[2]
                .takeUnless { it == NO_INVALID_SIGNAL }
                ?.toInt(),
            canId = schemaIntegerBuffer[3].toInt(),
            kind = schemaIntegerBuffer[4].toInt(),
            source = schemaIntegerBuffer[5].toInt(),
            width = schemaIntegerBuffer[6].toInt(),
            flags = schemaIntegerBuffer[7].toInt(),
            scale = schemaDecimalBuffer[0],
            offset = schemaDecimalBuffer[1],
            name = strings[0],
            unit = strings[1]
        )
    }

    override fun schema(): List<RoadcastSchemaEntry> {
        val count = status()?.signalCount ?: return emptyList()
        val entries = List(count) { index ->
            schemaEntryAt(index)
                ?: error("Roadcast schema entry $index is unavailable")
        }
        entries.forEachIndexed { index, entry ->
            require(entry.index == index) {
                "Roadcast schema index mismatch: requested $index, got ${entry.index}"
            }
            require(entry.name.isNotBlank()) {
                "Roadcast schema entry $index has no name"
            }
            require(entry.invalidSignalIndex == null || entry.invalidSignalIndex in entries.indices) {
                "Roadcast schema entry $index has invalid companion " +
                    "${entry.invalidSignalIndex}"
            }
        }
        return entries
    }

    override fun sampleAgeNs(): Long =
        if (handle == 0L) -1 else RoadcastNative.nativeSampleAgeNs(handle)

    override fun isAlive(maxAgeMs: Long): Boolean {
        val current = status() ?: return false
        val age = sampleAgeNs()
        return current.connected && age in 0 until maxAgeMs * 1_000_000L
    }

    override fun read(indices: IntArray, output: RoadcastReading): Int =
        if (handle == 0L) -1
        else RoadcastNative.nativeReadSignals(
            handle,
            indices,
            output.physical,
            output.raw,
            output.lastChangeNs,
            output.flags
        )

    override fun close() {
        if (handle == 0L) return
        RoadcastNative.nativeClose(handle)
        handle = 0L
    }

    companion object {
        const val DEFAULT_SOCKET_NAME = "@roadcast"
        private const val NO_INVALID_SIGNAL = 0xFFFF_FFFFL

        fun connect(socketName: String = DEFAULT_SOCKET_NAME): Result<RoadcastClient> {
            if (!RoadcastNative.ensureLoaded()) {
                return Result.failure(
                    IllegalStateException(
                        "libroadcast_jni failed to load: ${RoadcastNative.loadError()}"
                    )
                )
            }
            val error = IntArray(1)
            val handle = RoadcastNative.nativeConnect(socketName, error)
            if (handle == 0L) {
                return Result.failure(
                    IllegalStateException(RoadcastNative.nativeErrorString(error[0]))
                )
            }
            return Result.success(RoadcastClient(handle))
        }
    }
}
