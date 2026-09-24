# 1. Trip Energy Calculated via CAN Power Integral

## Context and Decision

Deriving trip energy by multiplying battery State of Charge (SOC) by rated capacity caused inconsistencies because SOC is a quantized state rather than an integrated rate. We decided to compute trip energy strictly as the time integral of measured CAN bus pack voltage and pack current (`TelemetryEnergy.tripPowerIntegral`).

## Consequences

- SOC is preserved as recorded telemetry state and used only for directional validation, not for energy totals.
- Dart layers only reduce stored 1-minute intervals and never re-integrate raw power frames.
