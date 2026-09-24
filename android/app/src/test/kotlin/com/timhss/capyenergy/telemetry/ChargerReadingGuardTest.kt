package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Os números vêm da captura de 2026-07-25 (2026-07-25 capture):
 * carregando, `DCHA_CHARGE_ACDC_VOLT`/`_CURRENT` andaram de 211.1 V / 6.8 A para
 * 211.6 V / 6.7 A em dois minutos; com a carga parada pela central e o plugue
 * ainda conectado, travaram em 215.0 V / 4.8 A por pelo menos 80 s enquanto o
 * `OBC_iInAct` no CAN já marcava zero.
 */
class ChargerReadingGuardTest {

    @Test
    fun `par que anda e medicao`() {
        val guard = ChargerReadingGuard()

        assertTrue(guard.read(pair(211.1f, 6.8f), seconds(0)) is ChargerReadingGuard.Result.Measuring)

        val later = guard.read(pair(211.6f, 6.7f), seconds(120))
        assertTrue(later is ChargerReadingGuard.Result.Measuring)
        // 211.6 V x 6.7 A = 1.418 kW
        assertEquals(
            1.418f,
            (later as ChargerReadingGuard.Result.Measuring).readings.inputPowerKw,
            0.001f
        )
    }

    @Test
    fun `par travado vira Frozen, nao zero`() {
        val guard = ChargerReadingGuard()
        guard.read(pair(215.0f, 4.8f), seconds(0))

        // Dentro da janela ainda é medição: uma carga estável não pode ser
        // descartada só por não ter mudado em alguns segundos.
        assertTrue(guard.read(pair(215.0f, 4.8f), seconds(80)) is ChargerReadingGuard.Result.Measuring)

        // Passada a janela, deixa de ser leitura. Frozen e não Measuring(0f):
        // não sabemos que a potência é zero, sabemos que não estamos medindo.
        assertEquals(ChargerReadingGuard.Result.Frozen, guard.read(pair(215.0f, 4.8f), seconds(95)))
    }

    @Test
    fun `voltar a andar destrava na hora`() {
        val guard = ChargerReadingGuard()
        guard.read(pair(215.0f, 4.8f), seconds(0))
        assertEquals(ChargerReadingGuard.Result.Frozen, guard.read(pair(215.0f, 4.8f), seconds(100)))

        // Foi o que aconteceu no carro quando a carga reiniciou a 7 A.
        assertTrue(
            guard.read(pair(211.6f, 6.7f), seconds(101)) is ChargerReadingGuard.Result.Measuring
        )
    }

    @Test
    fun `o timestamp do VHAL vale mais que o valor`() {
        val guard = ChargerReadingGuard()
        // Mesmo par de números, mas o VHAL republicou há pouco: é medição, não
        // é o valor que ficou preso. Foi o que o carro mostrou em 2026-07-26 —
        // 4.8000 A imóveis por minutos, com o carimbo andando a cada leitura.
        assertTrue(
            guard.read(pair(215.0f, 4.8f, vhalNanos = seconds(200)), seconds(200))
                is ChargerReadingGuard.Result.Measuring
        )
        assertTrue(
            guard.read(pair(215.0f, 4.8f, vhalNanos = seconds(260)), seconds(260))
                is ChargerReadingGuard.Result.Measuring
        )

        // E o inverso: carimbo velho é congelamento mesmo que o valor oscile.
        assertEquals(
            ChargerReadingGuard.Result.Frozen,
            guard.read(pair(215.4f, 4.9f, vhalNanos = seconds(260)), seconds(400))
        )
    }

    @Test
    fun `carimbo velho e reconhecido na primeira leitura`() {
        // Partida a frio: o guard acabou de nascer e a publicação é de uma hora
        // atrás. Como a idade é absoluta, não há período cego — foi por não ter
        // isso que o app voltou a gravar 20.5 kW logo após uma reinstalação.
        val guard = ChargerReadingGuard()
        val now = seconds(242_047)
        val publishedAnHourAgo = seconds(238_306)

        assertEquals(
            ChargerReadingGuard.Result.Frozen,
            guard.read(pair(215.0f, 4.8f, vhalNanos = publishedAnHourAgo), now)
        )
    }

    @Test
    fun `sem par nao ha leitura`() {
        val guard = ChargerReadingGuard()
        assertEquals(ChargerReadingGuard.Result.Absent, guard.read(emptyMap(), seconds(0)))

        // Tensão zero é registro vazio, não uma tomada de 0 V.
        assertEquals(ChargerReadingGuard.Result.Absent, guard.read(pair(0f, 0f), seconds(1)))
    }

    @Test
    fun `ausencia no meio nao envelhece a janela`() {
        val guard = ChargerReadingGuard()
        guard.read(pair(215.0f, 4.8f), seconds(0))
        // Um buraco na leitura zera o rastreio: a idade que interessa é a do
        // par contínuo, não a do último valor visto antes do buraco.
        guard.read(emptyMap(), seconds(50))
        assertTrue(guard.read(pair(215.0f, 4.8f), seconds(51)) is ChargerReadingGuard.Result.Measuring)
    }

    private fun seconds(value: Long): Long = value * 1_000_000_000L

    private fun pair(
        voltage: Float,
        current: Float,
        vhalNanos: Long? = null
    ): Map<SignalKey, SignalSample> = mapOf(
        SignalKey.HV_BATTERY_VOLTAGE to sample(SignalKey.HV_BATTERY_VOLTAGE, voltage, vhalNanos),
        SignalKey.HV_BATTERY_CURRENT to sample(SignalKey.HV_BATTERY_CURRENT, current, vhalNanos)
    )

    private fun sample(signalId: SignalKey, value: Float, vhalNanos: Long?): SignalSample =
        SignalSample(
            signalId = signalId,
            value = value,
            unit = "",
            quality = SignalQuality.MEASURED,
            source = SignalSource.VHAL_POLLING,
            propertyId = 0,
            propertyIdHex = "0x00000000",
            areaId = 0,
            timestamp = SignalTimestamp(
                receivedAtUtcMillis = 0L,
                receivedAtElapsedNanos = 0L,
                sourceTimestampNanos = vhalNanos,
                accuracy = TimestampAccuracy.POLLED,
                uncertaintyMillis = 0L
            ),
            details = "test"
        )
}
