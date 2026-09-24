package com.timhss.capyenergy.roadcast

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Minimal ADB host implementation for executing one legacy shell command through
 * the root adbd already listening on the vehicle loopback interface.
 */
internal class LocalAdbShell(
    private val host: String = DEFAULT_HOST,
    private val port: Int = DEFAULT_PORT
) {
    fun execute(command: String): String {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MILLIS)
            socket.soTimeout = IO_TIMEOUT_MILLIS

            val input = DataInputStream(socket.getInputStream())
            val output = DataOutputStream(socket.getOutputStream())
            AdbPacketCodec.write(
                output,
                AdbPacket(
                    command = A_CNXN,
                    arg0 = ADB_VERSION,
                    arg1 = MAX_ADB_PAYLOAD,
                    payload = "host::roadcast-supervisor\u0000".toByteArray()
                )
            )

            val handshake = AdbPacketCodec.read(input)
            when (handshake.command) {
                A_CNXN -> check(handshake.payload.toString(Charsets.UTF_8).contains("shell_v2")) {
                    "Local ADB does not support shell_v2"
                }
                A_AUTH -> error("Local ADB requires authentication")
                else -> error("Unexpected local ADB handshake: ${handshake.commandName}")
            }

            val localId = 1
            AdbPacketCodec.write(
                output,
                AdbPacket(
                    command = A_OPEN,
                    arg0 = localId,
                    arg1 = 0,
                    payload = shellService(command).toByteArray()
                )
            )

            var remoteId = 0
            val commandOutput = ByteArrayOutputStream()
            val shellDecoder = ShellV2Decoder { channel, payload ->
                if (channel == SHELL_STDOUT || channel == SHELL_STDERR) {
                    val remaining = MAX_COMMAND_OUTPUT_BYTES - commandOutput.size()
                    if (remaining > 0) {
                        commandOutput.write(payload, 0, payload.size.coerceAtMost(remaining))
                    }
                }
            }
            while (true) {
                val packet = AdbPacketCodec.read(input)
                when (packet.command) {
                    A_OKAY -> remoteId = packet.arg0
                    A_WRTE -> {
                        remoteId = packet.arg0
                        shellDecoder.accept(packet.payload)
                        AdbPacketCodec.write(
                            output,
                            AdbPacket(A_OKAY, localId, remoteId)
                        )
                    }
                    A_CLSE -> {
                        shellDecoder.finish()
                        AdbPacketCodec.write(
                            output,
                            AdbPacket(A_CLSE, localId, packet.arg0)
                        )
                        return commandOutput.toString(Charsets.UTF_8.name()).trim()
                    }
                    else -> error("Unexpected local ADB shell packet: ${packet.commandName}")
                }
            }
        }
    }

    companion object {
        private const val DEFAULT_HOST = "127.0.0.1"
        private const val DEFAULT_PORT = 5555
        private const val CONNECT_TIMEOUT_MILLIS = 2_000
        private const val IO_TIMEOUT_MILLIS = 5_000
        private const val MAX_COMMAND_OUTPUT_BYTES = 64 * 1024

        internal fun shellService(command: String): String =
            "shell,v2,raw:$command\u0000"
    }
}

internal class ShellV2Decoder(
    private val onPacket: (channel: Int, payload: ByteArray) -> Unit
) {
    private var pending = ByteArray(0)

    fun accept(bytes: ByteArray) {
        check(pending.size + bytes.size <= MAX_SHELL_BUFFER_BYTES) {
            "ADB shell_v2 response exceeds the buffer limit"
        }
        pending += bytes

        var offset = 0
        while (pending.size - offset >= SHELL_HEADER_BYTES) {
            val channel = pending[offset].toUByte().toInt()
            val payloadBytes = ByteBuffer.wrap(
                pending,
                offset + 1,
                Int.SIZE_BYTES
            ).order(ByteOrder.LITTLE_ENDIAN).int
            require(payloadBytes in 0..MAX_SHELL_PACKET_BYTES) {
                "Invalid ADB shell_v2 payload length: $payloadBytes"
            }
            val packetBytes = SHELL_HEADER_BYTES + payloadBytes
            if (pending.size - offset < packetBytes) break

            require(channel in SHELL_STDIN..SHELL_WINDOW_SIZE_CHANGE) {
                "Invalid ADB shell_v2 channel: $channel"
            }
            onPacket(
                channel,
                pending.copyOfRange(
                    offset + SHELL_HEADER_BYTES,
                    offset + packetBytes
                )
            )
            offset += packetBytes
        }

        if (offset > 0) {
            pending = pending.copyOfRange(offset, pending.size)
        }
    }

    fun finish() {
        check(pending.isEmpty()) { "Truncated ADB shell_v2 response" }
    }
}

internal data class AdbPacket(
    val command: Int,
    val arg0: Int = 0,
    val arg1: Int = 0,
    val payload: ByteArray = ByteArray(0)
) {
    val commandName: String
        get() = ByteBuffer.allocate(Int.SIZE_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(command)
            .array()
            .toString(Charsets.US_ASCII)
}

internal object AdbPacketCodec {
    fun write(output: DataOutputStream, packet: AdbPacket) {
        require(packet.payload.size <= MAX_ADB_PAYLOAD) {
            "ADB payload exceeds $MAX_ADB_PAYLOAD bytes"
        }
        val header = ByteBuffer.allocate(ADB_HEADER_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(packet.command)
            .putInt(packet.arg0)
            .putInt(packet.arg1)
            .putInt(packet.payload.size)
            .putInt(checksum(packet.payload))
            .putInt(packet.command xor -1)
            .array()
        output.write(header)
        output.write(packet.payload)
        output.flush()
    }

    fun read(input: DataInputStream): AdbPacket {
        val headerBytes = ByteArray(ADB_HEADER_BYTES)
        input.readFully(headerBytes)
        val header = ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN)
        val command = header.int
        val arg0 = header.int
        val arg1 = header.int
        val payloadBytes = header.int
        val expectedChecksum = header.int
        val magic = header.int

        require(magic == (command xor -1)) { "Invalid ADB command magic" }
        require(payloadBytes in 0..MAX_ADB_PAYLOAD) {
            "Invalid ADB payload length: $payloadBytes"
        }

        val payload = ByteArray(payloadBytes)
        input.readFully(payload)
        // ADB 1.0.1 allows peers to omit checksums by writing zero.
        require(expectedChecksum == 0 || expectedChecksum == checksum(payload)) {
            "Invalid ADB payload checksum"
        }
        return AdbPacket(command, arg0, arg1, payload)
    }

    private fun checksum(payload: ByteArray): Int =
        payload.fold(0) { sum, byte -> sum + byte.toUByte().toInt() }
}

internal const val A_SYNC = 0x434e5953
internal const val A_CNXN = 0x4e584e43
internal const val A_OPEN = 0x4e45504f
internal const val A_OKAY = 0x59414b4f
internal const val A_CLSE = 0x45534c43
internal const val A_WRTE = 0x45545257
internal const val A_AUTH = 0x48545541
internal const val ADB_VERSION = 0x01000001
internal const val ADB_HEADER_BYTES = 24
internal const val MAX_ADB_PAYLOAD = 4096
internal const val SHELL_STDIN = 0
internal const val SHELL_STDOUT = 1
internal const val SHELL_STDERR = 2
internal const val SHELL_EXIT = 3
internal const val SHELL_CLOSE_STDIN = 4
internal const val SHELL_WINDOW_SIZE_CHANGE = 5
internal const val SHELL_HEADER_BYTES = 5
internal const val MAX_SHELL_PACKET_BYTES = 64 * 1024
internal const val MAX_SHELL_BUFFER_BYTES = MAX_SHELL_PACKET_BYTES + SHELL_HEADER_BYTES
