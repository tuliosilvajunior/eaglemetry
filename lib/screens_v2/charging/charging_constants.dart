/// Named charge-limit presets, in percent.
const chargeLimitDailyPreset = 70;
const chargeLimitExtendedPreset = 85;
const chargeLimitMaxPreset = 100;
const chargeLimitNamedPresets = [
  chargeLimitDailyPreset,
  chargeLimitExtendedPreset,
  chargeLimitMaxPreset,
];

/// Cadence for redrawing the charge graph while a session is running.
///
/// The detail read recomputes every series from the session's stored frames, so
/// it costs more than the trip screen's in-memory live poll — this stays far
/// slower than that 1-second cadence. Charging power also moves on a scale of
/// minutes, not seconds, so a slower tick still reads as live on the chart.
///
/// Shared by the screen's query and the graph's growth, so the two cannot
/// drift apart.
const chargeDetailLiveInterval = Duration(seconds: 5);

/// The two faces of the middle card: the limit the car will stop at, and the
/// session as it is happening.
enum ChargePanelTab { level, graph }
