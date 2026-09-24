# 6. Battery Pack Capacity Sourced from Settings and Profile

## Context and Decision

The Android Automotive vehicle hardware abstraction layer (VHAL) returns unpopulated or arbitrary default values (e.g. 150 kWh on a 39.6 kWh battery) for `INFO_EV_BATTERY_CAPACITY`. We decided to remove all dynamic VHAL queries for pack capacity and instead source nominal pack capacity strictly from user settings, backed by vehicle profile defaults (`GeelyProfile.battery`).

## Consequences

- Pack capacity is deterministic and never polluted by fake OEM hardware defaults.
- Changing pack capacity in settings triggers a clean recalculation of battery cycles from base session records.
