package com.timhss.capyenergy.profile

/**
 * A way of reaching a vehicle's signals.
 *
 * The profile abstracts **which** signal; a transport abstracts **how to reach
 * it**. The two are siblings, not one inside the other: Roadcast is a decoded
 * CAN bus and is specific to this head unit, the property surface is Android
 * Automotive's own, and a dongle would be a third. Each answers a different
 * subset of the same canonical keys.
 *
 * The interface is deliberately small. It carries only what the collection
 * sequence needs to reason about a transport it does not know the type of:
 * start it, stop it, ask whether it is delivering, and ask which keys it can
 * answer for a given vehicle. Anything larger would be one transport's shape
 * imposed on the others.
 */
interface SignalTransport {

    /** Short name for a log line and a status map. Not an identifier. */
    val transportName: String

    /**
     * The keys this transport can answer for [profile].
     *
     * It is a question about the pair, not about the transport alone: the same
     * bus reader answers different keys on a vehicle whose profile binds
     * different signals to it, and on a vehicle that binds none it answers an
     * empty set — which is how a profile without a bus turns the transport off
     * rather than leaving it running with nothing to read.
     */
    fun answers(profile: VehicleProfile): Set<SignalKey>

    fun start()

    fun stop()

    /**
     * Whether readings are arriving now.
     *
     * A transport that has been started and is silent is not the same as one
     * that was never started, and a reader that cannot tell them apart reports
     * a quiet vehicle as a broken app.
     */
    fun isDelivering(): Boolean
}
