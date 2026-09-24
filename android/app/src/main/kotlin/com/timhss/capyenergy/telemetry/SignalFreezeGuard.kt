package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

/**
 * Diz se **um** sinal ainda é medição ou virou um valor parado.
 *
 * Irmão de um só canal do [ChargerReadingGuard], criado para `EV_DC_CHARGE_POWER`
 * depois da medição de 2026-07-26: com o carro carregando em AC a 1.04 kW, a
 * property da potência DC estava congelada em 41 cru — 20.5 kW depois da escala —
 * com o carimbo do VHAL parado havia mais de trinta minutos. O detector de sessão
 * a aceitava sem nenhum teste de frescor e ela vencia o par AC, que estava vivo.
 * O estrago era duplo e está no banco: `startPowerKw` gravou 20.5 kW numa carga de
 * 1.04 kW, e, como 20.5 nunca é menor que o limiar de fim, a sessão perdia o
 * caminho de encerrar por potência.
 *
 * ## A idade é absoluta, não relativa
 *
 * O carimbo do VHAL está na **mesma base** do `SystemClock.elapsedRealtimeNanos`
 * do app: nanossegundos desde o boot. Medido no carro em 2026-07-26 —
 * `/proc/uptime` marcava 242047.82 s no instante em que `DCHA_CHARGE_ACDC_VOLT`
 * trazia o carimbo 242047478321046, isto é, a property tinha 340 ms de idade.
 *
 * Isso permite responder na **primeira leitura**, sem janela de aquecimento. A
 * alternativa — cronometrar há quanto tempo o carimbo não muda — tem um buraco
 * de partida a frio que custou caro: logo depois de uma reinstalação, com a
 * potência DC congelada havia uma hora, o app voltou a gravar 20.5 kW porque a
 * janela tinha acabado de começar e ainda não sabia de nada. Idade absoluta não
 * tem esse buraco: 242047.5 − 238306.7 = 3741 s de idade já na primeira amostra.
 *
 * ## Por que só o carimbo de origem serve aqui
 *
 * O [ChargerReadingGuard] pode cair no par (tensão, corrente) quando não há
 * carimbo, porque dois números independentes não ficam idênticos bit a bit por
 * minutos numa carga real. Com um sinal só essa saída não existe: uma carga DC
 * legítima segura a mesma potência por minutos, e o valor sozinho não distingue
 * "parado porque acabou" de "parado porque está estável".
 *
 * Então, sem carimbo de origem, este guard **não acusa congelamento**. Afirmar
 * sem evidência aqui trocaria um erro por outro — deixaria de gravar a potência
 * de uma carga DC de verdade, que é o caso que mais importa medir.
 */
class SignalFreezeGuard(
    private val signalId: SignalKey,
    private val staleNanos: Long = DEFAULT_FREEZE_NANOS
) {

    sealed interface Result {
        data class Measuring(val value: Float) : Result

        /** O sinal existe mas parou no tempo: quem publicava parou de publicar. */
        data object Frozen : Result

        /** Sem leitura utilizável — nunca houve. */
        data object Absent : Result
    }

    /**
     * [nowElapsedNanos] tem de vir de `SystemClock.elapsedRealtimeNanos` — é a
     * base em que o VHAL carimba, e a subtração só significa idade por isso.
     */
    fun read(
        snapshot: Map<SignalKey, SignalSample>,
        nowElapsedNanos: Long
    ): Result {
        val sample = snapshot[signalId] ?: return Result.Absent
        val value = sample.floatValue() ?: return Result.Absent

        val sourceTimestamp = sample.timestamp.sourceTimestampNanos
            ?: return Result.Measuring(value)

        return if (nowElapsedNanos - sourceTimestamp >= staleNanos) {
            Result.Frozen
        } else {
            Result.Measuring(value)
        }
    }

    companion object {
        /** Mesma janela folgada do [ChargerReadingGuard], pelo mesmo motivo. */
        const val DEFAULT_FREEZE_NANOS = 90_000_000_000L
    }
}
