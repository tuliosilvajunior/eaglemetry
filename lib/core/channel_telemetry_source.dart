import 'dart:async';

import 'package:flutter/services.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'app_navigation_controller.dart';

/// The generated top-level event stream, under a name that does not collide
/// with the interface method [ChannelTelemetrySource.annotationsChanged].
Stream<AnnotationChangeWire> generatedAnnotationsChanged() =>
    annotationsChanged();

/// The car, over the method and event channels.
class ChannelTelemetrySource implements TelemetrySource {
  const ChannelTelemetrySource();

  /// The generated typed api. One instance: it holds no state beyond the
  /// binary messenger it was not given, so the default is used.
  static final _wire = TelemetryWireApi();

  static const _channel = MethodChannel('com.timhss.capyenergy/telemetry');
  static const _liveChannel = EventChannel(
    'com.timhss.capyenergy/telemetry/live',
  );

  static bool _incomingHandlerRegistered = false;
  static final _chargeControlDownloadProgressController =
      StreamController<double>.broadcast();

  static Stream<double> get chargeControlDownloadProgress =>
      _chargeControlDownloadProgressController.stream;

  static final _chargeTargetSocController = StreamController<int>.broadcast();

  static Stream<int> get chargeTargetSocChanges =>
      _chargeTargetSocController.stream;

  static final _chargeControlStateController =
      StreamController<ChargeControlState>.broadcast();

  static Stream<ChargeControlState> get chargeControlStateChanges =>
      _chargeControlStateController.stream;

  /// Listens for what the native side pushes on the shared channel.
  ///
  /// Registered on the first outgoing call rather than at import time, because
  /// a `const` source has no constructor to hang it on and the handler is only
  /// of use once the app is running. A push sent before that first call — the
  /// cold start the charge plug causes — is not lost: the bridge holds it, and
  /// `TelemetryApi.takePendingDestination` collects it.
  static void ensureIncomingHandlerRegistered() {
    if (_incomingHandlerRegistered) return;
    _incomingHandlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'navigateTo') {
        final args = call.arguments as Map?;
        final destination = args?['destination'] as String?;
        if (destination != null) {
          AppNavigationController.instance.navigateTo(destination);
        }
      } else if (call.method == 'chargeControlAppDownloadProgress') {
        final args = call.arguments as Map?;
        final progress = (args?['progress'] as num?)?.toDouble();
        if (progress != null) {
          _chargeControlDownloadProgressController.add(progress);
        }
      } else if (call.method == 'onChargeTargetSocChanged') {
        final args = call.arguments as Map?;
        final targetSoc = (args?['targetSoc'] as num?)?.toInt();
        if (targetSoc != null) {
          _chargeTargetSocController.add(targetSoc);
        }
      } else if (call.method == 'onChargeControlStateChanged') {
        final args = call.arguments as Map?;
        if (args != null) {
          final state = ChargeControlState.fromMap(
            Map<String, Object?>.from(args),
          );
          _chargeControlStateController.add(state);
          _chargeTargetSocController.add(state.targetSoc);
        }
      }
      return null;
    });
  }

  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final result = await callOrNull(method, arguments);
    if (result == null) {
      throw PlatformException(
        code: 'null-result',
        message: '$method returned no data',
      );
    }
    return result;
  }

  @override
  Future<Map<String, Object?>?> callOrNull(
    String method, [
    Map<String, Object?>? arguments,
  ]) {
    ensureIncomingHandlerRegistered();
    return _channel.invokeMapMethod<String, Object?>(method, arguments);
  }

  @override
  Stream<Map<String, Object?>> liveFrames() =>
      _liveChannel.receiveBroadcastStream().map(castTelemetryEventMap);

  /// One stream for every subscriber.
  ///
  /// The generated `sessionsChanged()` builds a fresh [EventChannel] on each
  /// call, and a second channel of the same name replaces the first one's
  /// message handler on the messenger. Two screens listening would therefore
  /// silence each other, and the v2 shell keeps every tab mounted, so that is
  /// the normal case rather than a corner. Building the channel once and
  /// sharing the broadcast stream it returns keeps one handler registered.
  static Stream<SessionChange>? _sessionChanges;

  static Stream<AnnotationChange>? _annotationChanges;

  /// Same rule as the session stream: one channel, one handler.
  @override
  Stream<AnnotationChange> annotationsChanged() => _annotationChanges ??=
      generatedAnnotationsChanged().map(AnnotationChange.fromWire);

  @override
  Stream<SessionChange> sessionChanges() =>
      _sessionChanges ??= sessionsChanged().map(SessionChange.fromWire);

  @override
  Future<StorageUsage> storageUsage() async {
    final map = await _channel.invokeMapMethod<String, Object?>(
      'getStorageUsage',
    );
    if (map == null) {
      return const StorageUsage(
        bytes: 0,
        databaseBytes: 0,
        walBytes: 0,
        shmBytes: 0,
      );
    }
    return StorageUsage.fromMap(map);
  }

  @override
  Future<List<Map<String, Object?>>> eventsForSession(String sessionId) async =>
      const [];

  @override
  Future<EnergyWindowBucketsResult> energyBucketsInWindow(int minutes) async =>
      EnergyWindowBucketsResult.fromWire(
        await _wire.getEnergyBucketsInWindow(minutes),
      );

  @override
  Future<EnergyWindowBucketsResult> parkedEnergyBucketsInWindow(
    int minutes,
  ) async => EnergyWindowBucketsResult.fromWire(
    await _wire.getParkedEnergyBucketsInWindow(minutes),
  );

  @override
  Future<LiveEnergyBucketsResult> liveEnergyBuckets() async =>
      LiveEnergyBucketsResult.fromWire(await _wire.getLiveEnergyBuckets());

  @override
  Future<LiveEnergyBucketsResult> liveEfficiencyBuckets() async =>
      LiveEnergyBucketsResult.fromWire(await _wire.getLiveEfficiencyBuckets());

  @override
  Future<LiveEnergyBucketsResult> liveChargeEnergyBuckets() async =>
      LiveEnergyBucketsResult.fromWire(
        await _wire.getLiveChargeEnergyBuckets(),
      );

  @override
  Future<LiveEnergyBucketsResult> liveContinuousEnergyBuckets() async =>
      LiveEnergyBucketsResult.fromWire(
        await _wire.getLiveContinuousEnergyBuckets(),
      );

  @override
  Future<RangeEstimate> rangeEstimate() async =>
      RangeEstimate.fromWire(await _wire.getRangeEstimate());

  @override
  Future<HeadingReading> heading() async =>
      HeadingReading.fromWire(await _wire.getHeading());

  @override
  Future<BatteryCyclesResult> batteryCycles(int limit) async =>
      BatteryCyclesResult.fromWire(await _wire.getBatteryCycles(limit));

  @override
  Future<BatteryCycleSessionsResult> batteryCycleSessions(int ordinal) async =>
      BatteryCycleSessionsResult.fromWire(
        await _wire.getBatteryCycleSessions(ordinal),
      );

  @override
  Future<InsightTripsResult> insightTrips(String? subjectId) async =>
      InsightTripsResult.fromWire(await _wire.getInsightTrips(subjectId));

  @override
  Future<InsightPlacesResult> insightPlaces() async =>
      InsightPlacesResult.fromWire(await _wire.getInsightPlaces());

  @override
  Future<InsightPlace> saveInsightPlace({
    String? id,
    required String name,
    required double latitude,
    required double longitude,
    double radiusM = kInsightPlaceRadiusM,
    String? autoName,
    int? autoNameUpdatedAtUtcMillis,
    String? autoNameSource,
  }) async {
    final wire = await _wire.saveInsightPlace(
      id,
      name,
      latitude,
      longitude,
      radiusM,
      autoName,
      autoNameUpdatedAtUtcMillis,
      autoNameSource,
    );
    return InsightPlace(
      id: wire.id,
      name: wire.name,
      latitude: wire.latitude,
      longitude: wire.longitude,
      radiusM: wire.radiusM,
      autoName: wire.autoName,
      autoNameUpdatedAtUtcMillis: wire.autoNameUpdatedAtUtcMillis,
      autoNameSource: wire.autoNameSource,
    );
  }

  @override
  Future<void> deleteInsightPlace(String id) => _wire.deleteInsightPlace(id);

  @override
  Future<ChargeMergeCandidatesResult> chargeMergeCandidates(int limit) async =>
      ChargeMergeCandidatesResult.fromWire(
        await _wire.getChargeMergeCandidates(limit),
      );

  @override
  Future<ChargeMergeResult> mergeChargeSessions(
    List<String> sessionIds,
  ) async =>
      ChargeMergeResult.fromWire(await _wire.mergeChargeSessions(sessionIds));

  @override
  Future<ChargeSessionCostUpdateResult> updateChargeSessionCost({
    required String sessionId,
    required double? costPerKwh,
    required double? paidAmount,
    required String currency,
  }) async => ChargeSessionCostUpdateResult.fromWire(
    await _wire.updateChargeSessionCost(
      sessionId,
      costPerKwh,
      paidAmount,
      currency,
    ),
  );

  @override
  Future<List<PreferenceRow>> preferenceRows() async => [
    for (final wire in await _wire.getPreferenceRows())
      PreferenceRow(
        scope: wire.scope,
        key: wire.key,
        value: wire.value,
        updatedAtUtcMillis: wire.updatedAtUtcMillis,
        origin: wire.origin,
        deletedAtUtcMillis: wire.deletedAtUtcMillis,
      ),
  ];

  @override
  Future<PreferenceRow?> savePreferenceRow({
    required String scope,
    required String key,
    String? value,
  }) async {
    final wire = await _wire.savePreferenceRow(scope, key, value);
    if (wire == null) return null;
    return PreferenceRow(
      scope: wire.scope,
      key: wire.key,
      value: wire.value,
      updatedAtUtcMillis: wire.updatedAtUtcMillis,
      origin: wire.origin,
      deletedAtUtcMillis: wire.deletedAtUtcMillis,
    );
  }

  @override
  Future<List<PreferenceProposal>> preferenceProposals() async => [
    for (final wire in await _wire.getPreferenceProposals())
      PreferenceProposal(
        id: wire.id,
        key: wire.key,
        value: wire.value,
        status: PreferenceProposalStatus.values.firstWhere(
          (candidate) => candidate.name == wire.status,
          orElse: () => PreferenceProposalStatus.pending,
        ),
        proposedAtUtcMillis: wire.proposedAtUtcMillis,
        updatedAtUtcMillis: wire.updatedAtUtcMillis,
        origin: wire.origin,
        decidedAtUtcMillis: wire.decidedAtUtcMillis,
      ),
  ];

  @override
  Future<PreferenceProposal?> proposePreference({
    required String key,
    String? value,
  }) async {
    final wire = await _wire.proposePreference(key, value);
    if (wire == null) return null;
    return PreferenceProposal(
      id: wire.id,
      key: wire.key,
      value: wire.value,
      status: PreferenceProposalStatus.values.firstWhere(
        (candidate) => candidate.name == wire.status,
        orElse: () => PreferenceProposalStatus.pending,
      ),
      proposedAtUtcMillis: wire.proposedAtUtcMillis,
      updatedAtUtcMillis: wire.updatedAtUtcMillis,
      origin: wire.origin,
      decidedAtUtcMillis: wire.decidedAtUtcMillis,
    );
  }

  @override
  Future<PreferenceProposal?> decidePreferenceProposal({
    required String id,
    required bool accept,
  }) async {
    final wire = await _wire.decidePreferenceProposal(id, accept);
    if (wire == null) return null;
    return PreferenceProposal(
      id: wire.id,
      key: wire.key,
      value: wire.value,
      status: PreferenceProposalStatus.values.firstWhere(
        (candidate) => candidate.name == wire.status,
        orElse: () => PreferenceProposalStatus.pending,
      ),
      proposedAtUtcMillis: wire.proposedAtUtcMillis,
      updatedAtUtcMillis: wire.updatedAtUtcMillis,
      origin: wire.origin,
      decidedAtUtcMillis: wire.decidedAtUtcMillis,
    );
  }
}
