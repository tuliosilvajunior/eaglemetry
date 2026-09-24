package com.timhss.capyenergy.roadcast

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalAdbShellTest {
    @Test
    fun `packet codec round trips little endian headers and payloads`() {
        val encoded = ByteArrayOutputStream()
        val expected = AdbPacket(
            command = A_OPEN,
            arg0 = 7,
            arg1 = 11,
            payload = "shell:id -Z\u0000".toByteArray()
        )

        AdbPacketCodec.write(DataOutputStream(encoded), expected)
        val actual = AdbPacketCodec.read(
            DataInputStream(ByteArrayInputStream(encoded.toByteArray()))
        )

        assertEquals(expected.command, actual.command)
        assertEquals(expected.arg0, actual.arg0)
        assertEquals(expected.arg1, actual.arg1)
        assertArrayEquals(expected.payload, actual.payload)
    }

    @Test
    fun `reader accepts checksum omission negotiated by ADB 1_0_1`() {
        val payload = "device::features=shell_v2\u0000".toByteArray()
        val encoded = ByteBuffer.allocate(ADB_HEADER_BYTES + payload.size)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(A_CNXN)
            .putInt(ADB_VERSION)
            .putInt(MAX_ADB_PAYLOAD)
            .putInt(payload.size)
            .putInt(0)
            .putInt(A_CNXN xor -1)
            .put(payload)
            .array()

        val packet = AdbPacketCodec.read(
            DataInputStream(ByteArrayInputStream(encoded))
        )

        assertEquals(A_CNXN, packet.command)
        assertArrayEquals(payload, packet.payload)
    }

    @Test
    fun `reader rejects invalid magic and oversized payloads`() {
        val invalidMagic = header(command = A_OKAY, payloadBytes = 0, magic = 0)
        assertThrows(IllegalArgumentException::class.java) {
            AdbPacketCodec.read(DataInputStream(ByteArrayInputStream(invalidMagic)))
        }

        val oversized = header(
            command = A_WRTE,
            payloadBytes = MAX_ADB_PAYLOAD + 1,
            magic = A_WRTE xor -1
        )
        assertThrows(IllegalArgumentException::class.java) {
            AdbPacketCodec.read(DataInputStream(ByteArrayInputStream(oversized)))
        }
    }

    @Test
    fun `shell v2 service requests raw framing`() {
        assertEquals(
            "shell,v2,raw:id -Z\u0000",
            LocalAdbShell.shellService("id -Z")
        )
    }

    @Test
    fun `shell v2 decoder handles fragmented and multiplexed packets`() {
        val decoded = mutableListOf<Pair<Int, String>>()
        val decoder = ShellV2Decoder { channel, payload ->
            decoded += channel to payload.toString(Charsets.UTF_8)
        }
        val stream = shellPacket(SHELL_STDOUT, "out") +
            shellPacket(SHELL_STDERR, "err") +
            shellPacket(SHELL_EXIT, "\u0000\u0000\u0000\u0000")

        decoder.accept(stream.copyOfRange(0, 2))
        decoder.accept(stream.copyOfRange(2, 9))
        decoder.accept(stream.copyOfRange(9, stream.size))
        decoder.finish()

        assertEquals(
            listOf(
                SHELL_STDOUT to "out",
                SHELL_STDERR to "err",
                SHELL_EXIT to "\u0000\u0000\u0000\u0000"
            ),
            decoded
        )
    }

    @Test
    fun `shell v2 decoder rejects truncated response`() {
        val decoder = ShellV2Decoder { _, _ -> }
        decoder.accept(byteArrayOf(SHELL_STDOUT.toByte(), 4, 0, 0, 0, 1))

        assertThrows(IllegalStateException::class.java) {
            decoder.finish()
        }
    }

    @Test
    fun `launch command requires external binary and emits readiness marker`() {
        val command = RoadcastDaemon.launchCommand()

        assertTrue(command.contains("/data/local/tmp/roadcastd"))
        assertTrue(command.contains("--socket @roadcast"))
        assertTrue(command.contains("--hz 60"))
        assertTrue(command.contains("ROADCAST_ERROR:missing"))
        assertTrue(command.contains("ROADCAST_LAUNCHED"))
    }

    @Test
    fun `runtime context command inspects every existing daemon process`() {
        val command = RoadcastDaemon.runtimeContextCommand()

        assertTrue(command.contains("pidof roadcastd"))
        assertTrue(command.contains("/proc/\"\$pid\"/attr/current"))
    }

    @Test
    fun `install command copies through root ADB and reports checksum`() {
        val digest = "67d782809700d044ea0f27640b8e55c1abb2b33e692131bd40dd9f467c80b7ab"
        val command = RoadcastDaemon.installCommand(
            "/data/user/0/com.timhss.capy/cache/roadcastd.install",
            digest
        )

        assertTrue(command.contains("pidof roadcastd"))
        assertTrue(command.contains("cp '/data/user/0/"))
        assertTrue(command.contains("/data/local/tmp/roadcastd.new"))
        assertTrue(command.contains("chmod 0755 /data/local/tmp/roadcastd.new"))
        assertTrue(command.contains("sha256sum /data/local/tmp/roadcastd.new"))
        assertTrue(command.contains(digest))
        assertTrue(command.contains("mv -f /data/local/tmp/roadcastd.new /data/local/tmp/roadcastd"))
    }

    @Test
    fun `checksum parser ignores diagnostics before the digest`() {
        val digest = "67d782809700d044ea0f27640b8e55c1abb2b33e692131bd40dd9f467c80b7ab"

        assertEquals(
            digest,
            RoadcastDaemon.parseSha256("warning\n$digest  /data/local/tmp/roadcastd")
        )
        assertEquals(null, RoadcastDaemon.parseSha256("ROADCAST_ERROR:install"))
    }

    private fun header(command: Int, payloadBytes: Int, magic: Int): ByteArray =
        ByteBuffer.allocate(ADB_HEADER_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(command)
            .putInt(0)
            .putInt(0)
            .putInt(payloadBytes)
            .putInt(0)
            .putInt(magic)
            .array()

    private fun shellPacket(channel: Int, payload: String): ByteArray {
        val payloadBytes = payload.toByteArray()
        return ByteBuffer.allocate(SHELL_HEADER_BYTES + payloadBytes.size)
            .order(ByteOrder.LITTLE_ENDIAN)
            .put(channel.toByte())
            .putInt(payloadBytes.size)
            .put(payloadBytes)
            .array()
    }
}
