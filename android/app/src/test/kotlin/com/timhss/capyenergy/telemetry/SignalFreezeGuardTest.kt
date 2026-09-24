package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Os números vêm da medição de 2026-07-26, com o carro carregando em AC:
 * `CHARGING_DIRECT_CURRENT_PWR` cru 41 — 20.5 kW depois da escala — com o
 * carimbo do VHAL parado em 238306663515978 havia mais de meia hora, enquanto a
 * carga real, medida pela entrada AC, era de 1.04 kW.
 */
class SignalFreezeGuardTest {

    private val signalId = SignalKey.EV_DC_CHARGE_POWER

    @Test
    fun `property parada no tempo deixa de ser medicao`() {
        val guard = SignalFreezeGuard(signalId)
        val published = 238_306_663_515_978L

        // Recém-publicada: medição.
        assertEquals(
            SignalFreezeGuard.Result.Measuring(20.5f),
            guard.read(dcPower(20.5f, published), published + seconds(1))
        )
        // A janela é folgada de propósito: perder uma carga real custa mais.
        assertEquals(
            SignalFreezeGuard.Result.Measuring(20.5f),
            guard.read(dcPower(20.5f, published), published + seconds(80))
        )
        assertEquals(
            SignalFreezeGuard.Result.Frozen,
            guard.read(dcPower(20.5f, published), published + seconds(95))
        )
    }

    @Test
    fun `carimbo velho e reconhecido na primeira leitura`() {
        // O número exato do carro em 2026-07-26: publicação em 238306.66 s de
        // uptime, relógio em 242047.5 s — 3741 s, mais de uma hora de idade.
        // Um guard sem estado responde certo já na primeira amostra; um que
        // cronometra "há quanto tempo não muda" ficaria 90 s cego, e foi assim
        // que 20.5 kW voltaram ao banco depois de uma reinstalação.
        val guard = SignalFreezeGuard(signalId)

        assertEquals(
            SignalFreezeGuard.Result.Frozen,
            guard.read(dcPower(20.5f, 238_306_663_515_978L), 242_047_478_321_046L)
        )
    }

    @Test
    fun `valor constante com carimbo andando continua sendo medicao`() {
        // O caso que quase custou caro. Em 2026-07-26 a corrente do carregador
        // ficou em 4.8000 A por mais de três minutos enquanto o carimbo do VHAL
        // avançava a cada leitura: valor parado não é publicação parada. Uma
        // carga DC de verdade segura a mesma potência do mesmo jeito.
        val guard = SignalFreezeGuard(signalId)
        var source = 240_535_392_154_648L

        repeat(30) { i ->
            source += seconds(10)
            assertEquals(
                "carga estável virou congelamento na iteração $i",
                SignalFreezeGuard.Result.Measuring(50f),
                guard.read(dcPower(50f, source), source + seconds(1))
            )
        }
    }

    @Test
    fun `sem carimbo de origem o guard nao acusa congelamento`() {
        // Com um sinal só, o valor sozinho não distingue "parado porque acabou"
        // de "parado porque está estável" — o par tensão/corrente pode cair no
        // valor porque são dois números independentes, aqui não há esse plano B.
        // Sem evidência, não se afirma.
        val guard = SignalFreezeGuard(signalId)

        assertEquals(
            SignalFreezeGuard.Result.Measuring(50f),
            guard.read(dcPower(50f, vhalNanos = null), seconds(0))
        )
        assertEquals(
            SignalFreezeGuard.Result.Measuring(50f),
            guard.read(dcPower(50f, vhalNanos = null), seconds(600))
        )
    }

    @Test
    fun `sinal ausente e ausencia, nao congelamento`() {
        val guard = SignalFreezeGuard(signalId)
        assertEquals(SignalFreezeGuard.Result.Absent, guard.read(emptyMap(), seconds(0)))
    }

    @Test
    fun `voltar a publicar destrava na hora`() {
        val guard = SignalFreezeGuard(signalId)
        val old = 238_306_663_515_978L
        val now = old + seconds(100)
        assertEquals(
            SignalFreezeGuard.Result.Frozen,
            guard.read(dcPower(20.5f, old), now)
        )

        // Uma publicação nova é medição imediatamente: não há estado a limpar.
        assertTrue(
            guard.read(dcPower(20.5f, now), now)
                is SignalFreezeGuard.Result.Measuring
        )
    }

    @Test
    fun `a leitura nao depende da ordem nem do historico`() {
        // Sem estado interno, duas instâncias vendo a mesma amostra respondem
        // igual — o que torna o guard seguro de compartilhar entre o detector
        // de sessão e o repositório de frames, que o chamam no mesmo ciclo.
        val old = 238_306_663_515_978L
        val now = old + seconds(3741)

        assertEquals(
            SignalFreezeGuard(signalId).read(dcPower(20.5f, old), now),
            SignalFreezeGuard(signalId).read(dcPower(20.5f, old), now)
        )
    }

    private fun seconds(value: Long): Long = value * 1_000_000_000L

    private fun dcPower(value: Float, vhalNanos: Long?): Map<SignalKey, SignalSample> = mapOf(
        signalId to SignalSample(
            signalId = signalId,
            value = value,
            unit = "kW",
            quality = SignalQuality.MEASURED,
            source = SignalSource.VHAL_CALLBACK,
            propertyId = 0,
            propertyIdHex = "0x00000000",
            areaId = 0,
            timestamp = SignalTimestamp(
                receivedAtUtcMillis = 0L,
                receivedAtElapsedNanos = 0L,
                sourceTimestampNanos = vhalNanos,
                accuracy = TimestampAccuracy.SOURCE_EVENT,
                uncertaintyMillis = 0L
            ),
            details = "test"
        )
    )
}
