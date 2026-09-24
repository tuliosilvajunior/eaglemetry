package com.timhss.capyenergy.telemetry

/** One bounded FIFO for every durable telemetry mutation. */
object TelemetryWriteCoordinator {
    val executor = ObservedWriteExecutor("telemetry", queueCapacity = 256)
}
