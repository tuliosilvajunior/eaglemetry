import 'package:flutter/foundation.dart';

import 'dto/telemetry_dto.dart';
import 'insight_place.dart';
import 'storage_usage.dart';
import 'sync_annotations.dart';

/// Everything about recorded data that is **not** one of the three questions.
///
/// Slice 5 moved the session reads to [TelemetryStore]: a list, a session and
/// its series are asked there, and no screen asks for them here. What is left
/// is the rest of the recorded surface — the change stream a list refreshes on,
/// the clock windows the energy monitor plots (which answer "now", and which
/// the store's interface must not carry), the battery cycles, the insights,
/// and the two annotations a reader can write.
///
/// A companion app (phone) implements this interface directly against its local
/// database without needing access to a live vehicle, vehicle controls, or
/// untyped platform invoke escape hatches.
abstract interface class HistoricalTelemetrySource {
  /// Fires when a session is written, closed, merged or priced.
  ///
  /// It does not fire per frame, so a list showing an open session still polls
  /// for that row's live values. A list with nothing open has nothing to poll
  /// for and can wait here.
  Stream<SessionChange> sessionChanges();

  /// Events that occurred during this session, oldest first.
  Future<List<Map<String, Object?>>> eventsForSession(String sessionId);

  /// The per-minute energy series over a window of clock.
  Future<EnergyWindowBucketsResult> energyBucketsInWindow(int minutes);

  /// The same window, over parked sessions instead of trips.
  Future<EnergyWindowBucketsResult> parkedEnergyBucketsInWindow(int minutes);

  /// The battery cycles, newest first. The read folds any newly closed
  /// session first, so the open cycle is current.
  Future<BatteryCyclesResult> batteryCycles(int limit);

  /// The sessions one cycle counted, oldest first. It does not fold first: the
  /// membership is written with the cycle.
  Future<BatteryCycleSessionsResult> batteryCycleSessions(int ordinal);

  /// Closed trips the Insights engine may compare.
  ///
  /// Session aggregates and minute-bucket presence only. Never frames.
  Future<InsightTripsResult> insightTrips(String? subjectId);

  /// Places the driver named.
  Future<InsightPlacesResult> insightPlaces();

  /// Names a place. [id] is set when renaming.
  ///
  /// [autoName] is the companion suggestion and is additive: rows without it
  /// stay valid, and readers show `name ?? autoName`.
  Future<InsightPlace> saveInsightPlace({
    String? id,
    required String name,
    required double latitude,
    required double longitude,
    double radiusM = kInsightPlaceRadiusM,
    String? autoName,
    int? autoNameUpdatedAtUtcMillis,
    String? autoNameSource,
  });

  Future<void> deleteInsightPlace(String id);

  /// Runs of charges that look like one session.
  Future<ChargeMergeCandidatesResult> chargeMergeCandidates(int limit);

  /// Merges a run into one session.
  Future<ChargeMergeResult> mergeChargeSessions(List<String> sessionIds);

  /// Prices a charge. The reply is the stored row, not the request.
  Future<ChargeSessionCostUpdateResult> updateChargeSessionCost({
    required String sessionId,
    required double? costPerKwh,
    required double? paidAmount,
    required String currency,
  });

  /// Fires when an annotation row — a place, a preference, a charge cost or
  /// a proposal — was written, merged or deleted. The reader re-reads the
  /// surface it shows.
  Stream<AnnotationChange> annotationsChanged();

  /// The synced preference rows this side holds, live and tombstones apart.
  Future<List<PreferenceRow>> preferenceRows();

  /// Writes one preference row from this side's own edit. Only a synced key
  /// may be written this way; an unknown key answers null.
  Future<PreferenceRow?> savePreferenceRow({
    required String scope,
    required String key,
    String? value,
  });

  /// The pending preference proposals shown as prompts.
  Future<List<PreferenceProposal>> preferenceProposals();

  /// Proposes a value for a car-only preference key. The proposal is inert
  /// until a person on the car accepts it.
  Future<PreferenceProposal?> proposePreference({
    required String key,
    String? value,
  });

  /// Decides a proposal. Acceptance runs the car's normal write path.
  Future<PreferenceProposal?> decidePreferenceProposal({
    required String id,
    required bool accept,
  });

  /// How much disk the app's stored history occupies.
  ///
  /// Must not scan every row: the cost would grow with history and the call
  /// is expected on the settings screen while the user waits.
  Future<StorageUsage> storageUsage();
}

/// Live vehicle operations, real-time CAN stream, and vehicle controls.
///
/// Only available when a live vehicle or active native collector is connected.
abstract interface class VehicleControlTelemetrySource {
  /// Calls [method] and returns its reply. Throws when there is no reply, so a
  /// broken channel cannot be read as an empty-but-valid answer.
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? arguments,
  ]);

  /// Calls [method] where no reply is a valid answer.
  Future<Map<String, Object?>?> callOrNull(
    String method, [
    Map<String, Object?>? arguments,
  ]);

  /// The live telemetry frames, as raw maps.
  Stream<Map<String, Object?>> liveFrames();

  /// The interval in progress and the last few closed ones, from memory.
  Future<LiveEnergyBucketsResult> liveEnergyBuckets();

  /// The same integral cut ten seconds wide, for the efficiency card.
  Future<LiveEnergyBucketsResult> liveEfficiencyBuckets();

  /// The open charge's climate minutes.
  ///
  /// Climate is the only term a charge integrates, so these buckets carry
  /// `climateWh` and nothing else. See [TelemetryApi.getLiveChargeEnergyBuckets].
  Future<LiveEnergyBucketsResult> liveChargeEnergyBuckets();

  /// The `CONTINUOUS` session's newest minutes. Empty with the mode off.
  Future<LiveEnergyBucketsResult> liveContinuousEnergyBuckets();

  /// The car's range and the app's estimate.
  Future<RangeEstimate> rangeEstimate();

  /// The GNSS course over ground, with the reason when there is none.
  Future<HeadingReading> heading();
}

/// Where a telemetry answer comes from.
///
/// There are two: the car, over the method channel, and the mock. The choice is
/// made once, by [defaultTelemetrySource], instead of at each of the 42 call
/// sites that used to carry both paths in one expression.
///
/// The old shape passed a `mock:` closure beside every real call. That closure
/// was built on every call, on the car as well, so the mock data reached the
/// release binary through an argument that was never used there.
///
/// Implements both [HistoricalTelemetrySource] and [VehicleControlTelemetrySource]
/// for the automotive app and testing mocks.
abstract interface class TelemetrySource
    implements HistoricalTelemetrySource, VehicleControlTelemetrySource {}

/// True when this build talks to the mock rather than to a car.
///
/// Both operands are compile-time constants, so on an Android release build
/// this folds to false and the mock source becomes unreachable code.
const bool useMockTelemetry =
    kIsWeb || bool.fromEnvironment('CAPY_MOCK_TELEMETRY');
