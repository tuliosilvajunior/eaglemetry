# 2. Heading Derived from GNSS Course

## Context and Decision

The head unit hardware lacks a calibrated magnetometer. We decided to derive vehicle heading exclusively from GNSS Course Over Ground (`Location.getBearing()`) when vehicle speed exceeds 1.5 km/h, and hold the last known course while stationary.

## Consequences

- The heading reflects the direction of travel rather than the vehicle's instantaneous orientation during complex manoeuvres.
- A stopped car maintains its heading display rather than showing unavailable or drifting.
- Yaw rate integration is deliberately avoided to prevent sensor drift errors.
