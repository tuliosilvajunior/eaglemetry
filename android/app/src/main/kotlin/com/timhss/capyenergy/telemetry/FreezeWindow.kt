package com.timhss.capyenergy.telemetry

/**
 * Mede há quanto tempo uma **chave de frescor** deixou de mudar.
 *
 * Extraído de [ChargerReadingGuard] quando a medição de 2026-07-26 mostrou que o
 * congelamento não é exclusivo do par tensão/corrente: `CHARGING_DIRECT_CURRENT_PWR`
 * estava parado em 41 (20.5 kW depois da escala) com o carimbo do VHAL trinta
 * minutos atrás, durante uma carga AC de 1.04 kW. Dois lugares precisando da mesma
 * conta é o momento de ela virar um tipo só.
 *
 * Não sabe nada sobre sinais: recebe uma chave, devolve se ela está parada. Quem
 * escolhe a chave é quem sabe o que é evidência de frescor naquele caso.
 */
internal class FreezeWindow(private val freezeNanos: Long) {

    private var lastKey: Any? = null
    private var lastChangedAtNanos: Long = 0L

    /**
     * `true` quando [key] não muda há pelo menos `freezeNanos`.
     *
     * [nowElapsedNanos] é o relógio local (`SystemClock.elapsedRealtimeNanos`),
     * usado só para medir a duração — nunca comparado com o carimbo de origem,
     * que tem outra base.
     */
    fun isFrozen(key: Any, nowElapsedNanos: Long): Boolean {
        if (key != lastKey) {
            lastKey = key
            lastChangedAtNanos = nowElapsedNanos
            return false
        }
        return nowElapsedNanos - lastChangedAtNanos >= freezeNanos
    }

    /**
     * Esquece a chave atual. A próxima leitura começa uma janela nova em vez de
     * herdar a idade da anterior — uma leitura que sumiu e voltou não é uma
     * leitura parada.
     */
    fun reset(nowElapsedNanos: Long = 0L) {
        lastKey = null
        lastChangedAtNanos = nowElapsedNanos
    }
}
