package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import kotlin.math.abs

/**
 * Decide quando a tensão e a corrente do carregador ainda são **medição**, e
 * quando viraram um valor parado.
 *
 * ## O bug que ele fecha
 *
 * Medido no carro em 2026-07-25: ao parar a carga pela central (sem tirar o
 * plugue), `DCHA_CHARGE_ACDC_CURRENT` ficou em 4.8 A e `_VOLT` em 215.0 V,
 * **congelados**, enquanto o `OBC_iInAct` no CAN foi a zero na hora. Oitenta
 * segundos depois continuavam ali. Voltaram a andar no instante em que a carga
 * reiniciou, então o congelamento é do lado de quem publica.
 *
 * Como o `SignalSample` é reescrito no store a cada leitura, o carimbo de
 * recepção continua novo e nenhuma checagem de frescor a jusante percebe nada:
 * o app seguia gravando ~1 kW de carga depois de a carga ter acabado, e o
 * detector de sessão nunca via potência baixa o bastante para encerrar.
 *
 * ## Como ele decide
 *
 * O que denuncia o congelamento não é o valor: é o **timestamp do próprio
 * VHAL** parar de avançar. E ele é comparável com o relógio local: está na mesma
 * base do `SystemClock.elapsedRealtimeNanos`, nanossegundos desde o boot. Medido
 * em 2026-07-26 — `/proc/uptime` em 242047.82 s contra o carimbo 242047478321046
 * de `DCHA_CHARGE_ACDC_VOLT`, 340 ms de idade. Então a idade é absoluta e vale já
 * na primeira leitura, sem esperar uma janela encher.
 *
 * Isso importa para a partida a frio. Cronometrar "há quanto tempo não muda" só
 * conta a partir do momento em que se começa a olhar: depois de uma
 * reinstalação, uma property congelada havia uma hora parecia nova por mais 90 s.
 *
 * Quando a origem não traz timestamp, cai para o par (tensão, corrente) como
 * chave: numa carga real esses dois números jamais ficam idênticos bit a bit
 * por minutos — a tensão da rede tem resolução de 0.1 V e oscila sempre. Na
 * captura, a corrente andou de 6.8 para 6.7 A em dois minutos.
 *
 * Congelado devolve **nulo, não zero**: não sabemos que a potência é zero,
 * sabemos que não estamos medindo. Zero seria inventar a leitura que falta —
 * e é justamente o que enche o rabo de cada sessão de carga com energia que
 * não existiu.
 */
class ChargerReadingGuard {

    /**
     * Entrada AC do carregador. O nome dos sinais diz "HV_BATTERY", mas o que
     * `DCHA_CHARGE_ACDC_*` descreve é a tomada (211 V, 6.8 A medidos), não o
     * pacote de 395 V — a diferença entre esta potência e a do pacote é
     * exatamente a perda do carregador.
     */
    data class ChargerReadings(val voltageV: Float, val currentA: Float) {
        val inputPowerKw: Float get() = abs(currentA) * voltageV / 1_000f
    }

    /**
     * O que o carregador está dizendo agora.
     *
     * [Frozen] e [Absent] são separados de propósito: os dois impedem gravar um
     * número, mas só o primeiro é **evidência** de que a carga parou — quem
     * estava publicando parou de publicar. Um detector de sessão pode agir
     * sobre isso; sobre ausência, não.
     */
    sealed interface Result {
        data class Measuring(val readings: ChargerReadings) : Result

        /** O par existe mas parou no tempo: carregador desligado. */
        data object Frozen : Result

        /** Sem leitura utilizável — nunca houve, ou é implausível. */
        data object Absent : Result
    }

    private val window = FreezeWindow(FREEZE_NANOS)

    /**
     * [nowElapsedNanos] é o relógio local (`SystemClock.elapsedRealtimeNanos`),
     * usado só para medir há quanto tempo a chave não muda.
     */
    @Synchronized
    fun read(
        snapshot: Map<SignalKey, SignalSample>,
        nowElapsedNanos: Long
    ): Result {
        val voltageSample = snapshot[SignalKey.HV_BATTERY_VOLTAGE]
        val currentSample = snapshot[SignalKey.HV_BATTERY_CURRENT]
        val voltage = voltageSample?.floatValue()
        val current = currentSample?.floatValue()
        if (voltage == null || current == null) {
            // Sem par não há o que rastrear; a próxima leitura completa começa
            // uma janela nova em vez de herdar a idade da anterior.
            window.reset(nowElapsedNanos)
            return Result.Absent
        }

        val voltageTs = voltageSample.timestamp.sourceTimestampNanos
        val currentTs = currentSample.timestamp.sourceTimestampNanos
        val frozen = if (voltageTs != null && currentTs != null) {
            // Idade absoluta: a publicação mais recente das duas é a que conta.
            nowElapsedNanos - maxOf(voltageTs, currentTs) >= FREEZE_NANOS
        } else {
            window.isFrozen(voltage to current, nowElapsedNanos)
        }
        if (frozen) return Result.Frozen

        if (voltage <= 0f) return Result.Absent
        return Result.Measuring(ChargerReadings(voltageV = voltage, currentA = current))
    }

    /** Atalho para quem só quer o número quando ele é medição. */
    fun readings(
        snapshot: Map<SignalKey, SignalSample>,
        nowElapsedNanos: Long
    ): ChargerReadings? = (read(snapshot, nowElapsedNanos) as? Result.Measuring)?.readings

    @Synchronized
    fun reset() = window.reset()

    companion object {
        /**
         * Idade máxima da publicação antes de a leitura deixar de contar como
         * medição — ou, no plano B sem carimbo, quanto tempo o par pode ficar
         * parado.
         *
         * Noventa segundos é folgado de propósito: o custo de um falso positivo
         * (perder potência numa carga de verdade) é maior que o de esperar um
         * pouco mais para reconhecer o congelamento, porque o detector de
         * sessão ainda tem o estado de carga como caminho primário para
         * encerrar. Na captura, o par mudou várias vezes por minuto enquanto
         * carregava.
         */
        private const val FREEZE_NANOS = 90_000_000_000L
    }
}
