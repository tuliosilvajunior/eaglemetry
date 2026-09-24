import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'can_bridge_models.dart';

final class _RoadcastClientStatus extends Struct {
  @Uint32()
  external int hz;

  @Uint32()
  external int frameCount;

  @Uint32()
  external int signalCount;

  @Uint32()
  external int schemaVersion;

  @Uint64()
  external int schemaHash;

  @Uint64()
  external int sampleSequence;

  @Uint64()
  external int changeSequence;

  @Uint64()
  external int sampleTimestampNs;

  @Uint64()
  external int droppedBatches;

  @Uint64()
  external int coalescedSamples;

  @Uint64()
  external int resynchronizations;

  @Uint32()
  external int effectiveHzMillihz;

  @Uint8()
  external int sourceState;

  @Uint8()
  external int connected;
}

final class _RoadcastSignalValue extends Struct {
  @Uint64()
  external int raw;

  @Double()
  external double physical;

  @Uint64()
  external int firstObservedNs;

  @Uint64()
  external int lastChangeNs;

  @Uint8()
  external int state;

  @Uint8()
  external int calibrated;
}

final class _RoadcastSchemaEntry extends Struct {
  @Uint64()
  external int stableId;

  @Uint32()
  external int index;

  @Uint32()
  external int invalidSignalIndex;

  @Uint16()
  external int canId;

  @Uint8()
  external int kind;

  @Uint8()
  external int source;

  @Uint8()
  external int width;

  @Uint8()
  external int flags;

  @Double()
  external double scale;

  @Double()
  external double offset;

  @Array(64)
  external Array<Char> name;

  @Array(16)
  external Array<Char> unit;
}

typedef _ConnectNative =
    Pointer<Void> Function(Pointer<Utf8> socketName, Pointer<Int32> error);
typedef _ConnectDart =
    Pointer<Void> Function(Pointer<Utf8> socketName, Pointer<Int32> error);
typedef _CloseNative = Void Function(Pointer<Void> client);
typedef _CloseDart = void Function(Pointer<Void> client);
typedef _StatusNative =
    Int32 Function(Pointer<Void> client, Pointer<_RoadcastClientStatus> status);
typedef _StatusDart =
    int Function(Pointer<Void> client, Pointer<_RoadcastClientStatus> status);
typedef _FindSignalNative =
    Int32 Function(Pointer<Void> client, Pointer<Utf8> name);
typedef _FindSignalDart =
    int Function(Pointer<Void> client, Pointer<Utf8> name);
typedef _SchemaAtNative =
    Pointer<_RoadcastSchemaEntry> Function(Pointer<Void> client, Uint32 index);
typedef _SchemaAtDart =
    Pointer<_RoadcastSchemaEntry> Function(Pointer<Void> client, int index);
typedef _ReadSignalsNative =
    Int32 Function(
      Pointer<Void> client,
      Pointer<Uint32> indices,
      UintPtr count,
      Pointer<_RoadcastSignalValue> values,
    );
typedef _ReadSignalsDart =
    int Function(
      Pointer<Void> client,
      Pointer<Uint32> indices,
      int count,
      Pointer<_RoadcastSignalValue> values,
    );
typedef _SampleAgeNative = Int64 Function(Pointer<Void> client);
typedef _SampleAgeDart = int Function(Pointer<Void> client);
typedef _ErrorStringNative = Pointer<Utf8> Function(Int32 error);
typedef _ErrorStringDart = Pointer<Utf8> Function(int error);

/// Dart FFI session backed by Roadcast's in-process client cache.
///
/// Socket I/O, schema paging, live updates, and resynchronization happen inside
/// `libroadcast_client.so`. A UI sample performs one FFI call and copies only the
/// requested cached values; it does not perform socket I/O on the Flutter thread.
class RoadcastFfi {
  RoadcastFfi._(
    this._library,
    this._handle,
    this._status,
    this.signalCount,
    this.frameCount,
    this.hz,
    this.schemaHash,
  );

  static const String _libraryName = 'libroadcast_client.so';
  static const String defaultSocketName = '@roadcast';
  static const int _observationValid = 2;
  static const int _noInvalidSignal = 0xffffffff;
  static String? lastAttachError;

  final DynamicLibrary _library;
  Pointer<Void> _handle;
  final Pointer<_RoadcastClientStatus> _status;

  final int signalCount;
  final int frameCount;
  final int hz;
  final int schemaHash;

  late final _CloseDart _close = _library
      .lookupFunction<_CloseNative, _CloseDart>('roadcast_client_close');
  late final _StatusDart _readStatus = _library
      .lookupFunction<_StatusNative, _StatusDart>('roadcast_client_status');
  late final _FindSignalDart _findSignal = _library
      .lookupFunction<_FindSignalNative, _FindSignalDart>(
        'roadcast_client_find_signal',
      );
  late final _SchemaAtDart _schemaAt = _library
      .lookupFunction<_SchemaAtNative, _SchemaAtDart>(
        'roadcast_client_schema_at',
      );
  late final _ReadSignalsDart _readSignals = _library
      .lookupFunction<_ReadSignalsNative, _ReadSignalsDart>(
        'roadcast_client_read_signals',
      );
  late final _SampleAgeDart _sampleAge = _library
      .lookupFunction<_SampleAgeNative, _SampleAgeDart>(
        'roadcast_client_sample_age_ns',
      );

  Pointer<Uint32>? _indices;
  Pointer<_RoadcastSignalValue>? _nativeValues;
  Pointer<Double>? _values;
  Pointer<Uint64>? _raws;
  Pointer<Int64>? _timestamps;
  Pointer<Int64>? _firstObserved;
  Pointer<Uint8>? _flags;
  int _capacity = 0;

  bool get isAttached => _handle != nullptr;

  static RoadcastFfi? attach({
    String socketName = defaultSocketName,
    String libraryName = _libraryName,
  }) {
    lastAttachError = null;
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(libraryName);
    } on Object catch (error) {
      lastAttachError = 'native library load failed: $error';
      return null;
    }

    final connect = library.lookupFunction<_ConnectNative, _ConnectDart>(
      'roadcast_client_connect',
    );
    final close = library.lookupFunction<_CloseNative, _CloseDart>(
      'roadcast_client_close',
    );
    final readStatus = library.lookupFunction<_StatusNative, _StatusDart>(
      'roadcast_client_status',
    );
    final errorString = library
        .lookupFunction<_ErrorStringNative, _ErrorStringDart>(
          'roadcast_client_error_string',
        );

    final socket = socketName.toNativeUtf8();
    final error = calloc<Int32>();
    final status = calloc<_RoadcastClientStatus>();
    try {
      final handle = connect(socket, error);
      if (handle == nullptr) {
        lastAttachError = errorString(error.value).toDartString();
        calloc.free(status);
        return null;
      }
      if (readStatus(handle, status) < 0 || status.ref.connected == 0) {
        lastAttachError = 'native client returned an unavailable cache';
        close(handle);
        calloc.free(status);
        return null;
      }
      return RoadcastFfi._(
        library,
        handle,
        status,
        status.ref.signalCount,
        status.ref.frameCount,
        status.ref.hz,
        status.ref.schemaHash,
      );
    } finally {
      calloc.free(socket);
      calloc.free(error);
    }
  }

  /// Returns the immutable schema negotiated by the native Roadcast client.
  List<RoadcastSchemaEntry> schema() {
    if (!isAttached) return const [];
    return List<RoadcastSchemaEntry>.generate(signalCount, (index) {
      final pointer = _schemaAt(_handle, index);
      if (pointer == nullptr) {
        throw StateError('Roadcast schema entry $index is unavailable');
      }
      final entry = pointer.ref;
      final invalidSignalIndex = entry.invalidSignalIndex == _noInvalidSignal
          ? null
          : entry.invalidSignalIndex;
      final name = _decodeCString(entry.name, 64);
      if (entry.index != index) {
        throw StateError(
          'Roadcast schema index mismatch: requested $index, got ${entry.index}',
        );
      }
      if (name.isEmpty) {
        throw StateError('Roadcast schema entry $index has no name');
      }
      if (invalidSignalIndex != null && invalidSignalIndex >= signalCount) {
        throw StateError(
          'Roadcast schema entry $index has invalid companion '
          '$invalidSignalIndex',
        );
      }
      return RoadcastSchemaEntry(
        stableId: entry.stableId,
        index: entry.index,
        invalidSignalIndex: invalidSignalIndex,
        canId: entry.canId,
        kind: entry.kind,
        source: entry.source,
        width: entry.width,
        flags: entry.flags,
        scale: entry.scale,
        offset: entry.offset,
        name: name,
        unit: _decodeCString(entry.unit, 16),
      );
    }, growable: false);
  }

  /// Resolves unique signal names against the negotiated schema.
  List<int> indicesOf(List<String> names) {
    if (!isAttached) return List<int>.filled(names.length, -1);
    final indices = <int>[];
    for (final name in names) {
      final pointer = name.toNativeUtf8();
      try {
        indices.add(_findSignal(_handle, pointer));
      } finally {
        calloc.free(pointer);
      }
    }
    return indices;
  }

  static String _decodeCString(Array<Char> chars, int capacity) {
    final bytes = <int>[];
    for (var index = 0; index < capacity; index++) {
      final value = chars[index] & 0xff;
      if (value == 0) break;
      bytes.add(value);
    }
    return utf8.decode(bytes);
  }

  int sampleSequence() {
    if (!isAttached || _readStatus(_handle, _status) < 0) return 0;
    return _status.ref.sampleSequence;
  }

  int sampleAgeNanos() => isAttached ? _sampleAge(_handle) : -1;

  bool isAlive({Duration maxAge = const Duration(milliseconds: 500)}) {
    if (!isAttached || _readStatus(_handle, _status) < 0) return false;
    final age = _sampleAge(_handle);
    return _status.ref.connected != 0 &&
        age >= 0 &&
        age < maxAge.inMicroseconds * 1000;
  }

  void _ensureCapacity(int count) {
    if (_capacity >= count) return;
    _freeBuffers();
    _indices = calloc<Uint32>(count);
    _nativeValues = calloc<_RoadcastSignalValue>(count);
    _values = calloc<Double>(count);
    _raws = calloc<Uint64>(count);
    _timestamps = calloc<Int64>(count);
    _firstObserved = calloc<Int64>(count);
    _flags = calloc<Uint8>(count);
    _capacity = count;
  }

  CanBridgeReading read(List<int> indices) {
    if (!isAttached) {
      throw StateError('Roadcast session is closed');
    }
    if (indices.isEmpty) {
      _ensureCapacity(1);
      return CanBridgeReading(
        values: _values!.asTypedList(0),
        raws: _raws!.asTypedList(0),
        timestampsNs: _timestamps!.asTypedList(0),
        firstObservedNs: _firstObserved!.asTypedList(0),
        flags: _flags!.asTypedList(0),
      );
    }

    _ensureCapacity(indices.length);
    for (var i = 0; i < indices.length; i++) {
      _indices![i] = indices[i];
    }
    final result = _readSignals(
      _handle,
      _indices!,
      indices.length,
      _nativeValues!,
    );
    if (result < 0) {
      throw StateError('Roadcast cache read failed ($result)');
    }

    final count = indices.length;
    for (var i = 0; i < count; i++) {
      final native = _nativeValues![i];
      _values![i] = native.physical;
      _raws![i] = native.raw;
      _timestamps![i] = native.lastChangeNs;
      _firstObserved![i] = native.firstObservedNs;
      _flags![i] =
          (native.state == _observationValid ? 0x01 : 0x00) |
          (native.calibrated != 0 ? 0x02 : 0x00);
    }
    return CanBridgeReading(
      values: _values!.asTypedList(count),
      raws: _raws!.asTypedList(count),
      timestampsNs: _timestamps!.asTypedList(count),
      firstObservedNs: _firstObserved!.asTypedList(count),
      flags: _flags!.asTypedList(count),
    );
  }

  void _freeBuffers() {
    if (_indices != null) calloc.free(_indices!);
    if (_nativeValues != null) calloc.free(_nativeValues!);
    if (_values != null) calloc.free(_values!);
    if (_raws != null) calloc.free(_raws!);
    if (_timestamps != null) calloc.free(_timestamps!);
    if (_firstObserved != null) calloc.free(_firstObserved!);
    if (_flags != null) calloc.free(_flags!);
    _indices = null;
    _nativeValues = null;
    _values = null;
    _raws = null;
    _timestamps = null;
    _firstObserved = null;
    _flags = null;
    _capacity = 0;
  }

  void detach() {
    if (_handle == nullptr) return;
    _close(_handle);
    _handle = nullptr;
    _freeBuffers();
    calloc.free(_status);
  }
}
