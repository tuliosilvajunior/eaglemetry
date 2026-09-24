import 'dart:async';

import 'can_bridge_models.dart';
import 'roadcast_ffi.dart' if (dart.library.js_interop) 'roadcast_ffi_web.dart';

/// Dart facade for live CAN values. Widgets use this class rather than invoking
/// native symbols directly.
///
/// Roadcast owns socket I/O and a native RAM cache. Sampling from the render path
/// is one synchronous FFI cache read, with no platform channel or socket syscall.
/// Kotlin negotiates the same schema through the JNI wrapper.
class CanBridge {
  CanBridge._(this._ffi, this.schema, this.entries)
    : _indices = [for (final entry in entries) entry.index],
      names = [for (final entry in entries) entry.name];

  final RoadcastFfi _ffi;
  final List<RoadcastSchemaEntry> schema;
  final List<RoadcastSchemaEntry> entries;
  final List<int> _indices;

  /// Nomes observados, na ordem em que [sample] devolve os valores.
  final List<String> names;

  bool _disposed = false;

  int get signalCount => _ffi.signalCount;

  int get hz => _ffi.hz;

  /// Connects to Roadcast and resolves [signals] against its negotiated schema.
  ///
  /// Returns null when the daemon or native library is unavailable. Unknown
  /// names are omitted so optional watchlist signals degrade independently.
  static Future<CanBridge?> connect({
    List<String>? signals,
    String socketName = RoadcastFfi.defaultSocketName,
  }) async {
    final ffi = RoadcastFfi.attach(socketName: socketName);
    if (ffi == null) return null;

    try {
      final schema = ffi.schema();
      final entries = signals == null
          ? schema
          : [
              for (final index in ffi.indicesOf(signals))
                if (index >= 0 && index < schema.length) schema[index],
            ];
      return CanBridge._(
        ffi,
        List.unmodifiable(schema),
        List.unmodifiable(entries),
      );
    } on Object {
      ffi.detach();
      rethrow;
    }
  }

  /// Lê os sinais observados. Chame no paint — custa uma travessia FFI, sem syscall.
  ///
  /// As listas do retorno são views sobre buffers reaproveitados: válidas até a
  /// próxima chamada. Para guardar, copie.
  CanBridgeReading sample() {
    if (_disposed) {
      throw StateError('CanBridge já foi liberada');
    }
    return _ffi.read(_indices);
  }

  /// Valor de um sinal pelo nome, para leitura pontual fora do caminho quente.
  double? valueOf(String name) {
    final position = names.indexOf(name);
    if (position < 0) return null;
    final reading = sample();
    return reading.isValidAt(position) ? reading.valueAt(position) : null;
  }

  /// False when the native reader disconnected or its latest sample is stale.
  bool get isAlive => !_disposed && _ffi.isAlive();

  /// Age of the most recent daemon sample.
  Duration get pollAge => Duration(microseconds: _ffi.sampleAgeNanos() ~/ 1000);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ffi.detach();
  }
}
