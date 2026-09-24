package com.timhss.capyenergy.roadcast

/** A domain projection over one atomic Roadcast snapshot. */
interface RoadcastSignalProvider<T> {
    val requiredSignals: Set<String>

    fun read(snapshot: RoadcastSnapshot): T
}
