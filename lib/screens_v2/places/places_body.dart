// Platform-agnostic body for "Consultar locais".
//
// This file re-exports the shared body from capy_ui so the car scaffold
// can mount it without a separate implementation. The companion app imports
// the same body directly from capy_ui.
export 'package:capy_ui/capy_ui.dart' show PlacesBody;
export 'package:telemetry_core/telemetry_core.dart'
    show PlacesData, NamedPlaceEntry, buildPlacesData;
