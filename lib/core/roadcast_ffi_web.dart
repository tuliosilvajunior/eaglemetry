import 'can_bridge_models.dart';

/// Web adapter for the native Roadcast client.
///
/// Browsers cannot load `libroadcast_client.so` or import `dart:ffi`. Returning
/// null from [attach] preserves the same "daemon unavailable" contract used on
/// Android when the native client cannot connect, while keeping mock/history
/// surfaces buildable for visual development.
class RoadcastFfi {
  static const String defaultSocketName = '@roadcast';
  static String? lastAttachError;

  static RoadcastFfi? attach({
    String socketName = defaultSocketName,
    String libraryName = 'libroadcast_client.so',
  }) {
    lastAttachError = 'Roadcast FFI is unavailable in web browsers';
    return null;
  }

  int get signalCount => 0;
  int get frameCount => 0;
  int get hz => 0;
  int get schemaHash => 0;

  List<RoadcastSchemaEntry> schema() => const <RoadcastSchemaEntry>[];

  List<int> indicesOf(List<String> names) => List<int>.filled(names.length, -1);

  CanBridgeReading read(List<int> indices) {
    throw UnsupportedError('Roadcast FFI is unavailable in web browsers');
  }

  bool isAlive({Duration maxAge = const Duration(milliseconds: 500)}) => false;

  int sampleAgeNanos() => -1;

  void detach() {}
}
