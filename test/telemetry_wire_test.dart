import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// The two routes into every migrated DTO must answer the same thing.
///
/// The car goes through the generated classes; the mock still arrives as a map.
/// While both exist, this is what stops them drifting — a field the wire spells
/// one way and the map another would otherwise show up only on the device that
/// uses that route.
void main() {
  group('energy buckets', () {
    EnergyBucketWire bucket(int startUtcMillis) => EnergyBucketWire(
      startUtcMillis: startUtcMillis,
      tractionWh: 120.5,
      regeneratedWh: 40.25,
      auxiliaryWh: 12.0,
      integratedSeconds: 60,
      speedDistanceKm: 1.2,
      odometerDistanceKm: 1.1,
      speedIntegratedSeconds: 58,
      climateWh: 3.5,
      climateIntegratedSeconds: 55,
      deliveredWh: 7.25,
    );

    Map<String, Object?> bucketMap(int startUtcMillis) => {
      'startUtcMillis': startUtcMillis,
      'tractionWh': 120.5,
      'regeneratedWh': 40.25,
      'auxiliaryWh': 12.0,
      'integratedSeconds': 60,
      'speedDistanceKm': 1.2,
      'odometerDistanceKm': 1.1,
      'speedIntegratedSeconds': 58,
      'climateWh': 3.5,
      'climateIntegratedSeconds': 55,
      'deliveredWh': 7.25,
    };

    test('every column survives the wire exactly as it survives the map', () {
      final wired = EnergyBucket.fromWire(bucket(1735689600000));
      final mapped = EnergyBucket.fromMap(bucketMap(1735689600000));

      expect(wired.start, mapped.start);
      expect(wired.tractionWh, mapped.tractionWh);
      expect(wired.regeneratedWh, mapped.regeneratedWh);
      expect(wired.auxiliaryWh, mapped.auxiliaryWh);
      expect(wired.integratedSeconds, mapped.integratedSeconds);
      expect(wired.speedDistanceKm, mapped.speedDistanceKm);
      expect(wired.odometerDistanceKm, mapped.odometerDistanceKm);
      expect(wired.speedIntegratedSeconds, mapped.speedIntegratedSeconds);
      expect(wired.climateWh, mapped.climateWh);
      expect(wired.climateIntegratedSeconds, mapped.climateIntegratedSeconds);
      expect(wired.deliveredWh, mapped.deliveredWh);
    });

    test('the width comes from the envelope, not from the bucket', () {
      final series = LiveEnergyBucketsResult.fromWire(
        LiveEnergyBucketsWire(
          bucketMillis: 10000,
          buckets: [bucket(1735689600000), bucket(1735689610000)],
          sessionId: 'trip-1',
          startedAtUtcMillis: 1735689600000,
        ),
      );

      expect(series.width, const Duration(seconds: 10));
      expect(
        series.buckets.every((b) => b.width == const Duration(seconds: 10)),
        isTrue,
        reason: 'a series cut ten seconds wide has no one-minute bucket in it',
      );
      expect(series.isActive, isTrue);
    });

    test('no trip running is not a failed read', () {
      final series = LiveEnergyBucketsResult.fromWire(
        LiveEnergyBucketsWire(bucketMillis: 60000, buckets: const []),
      );

      expect(series.isActive, isFalse);
      expect(series.sessionId, isNull);
      expect(series.startedAt, isNull);
      expect(series.buckets, isEmpty);
      expect(series.width, EnergyBucket.oneMinute);
    });
    test('an unsynced series crosses the wire and the map alike', () {
      final wired = LiveEnergyBucketsResult.fromWire(
        LiveEnergyBucketsWire(
          bucketMillis: 10000,
          buckets: const [],
          timeUnsynced: true,
        ),
      );
      final mapped = LiveEnergyBucketsResult.fromMap({
        'bucketMillis': 10000,
        'buckets': const [],
        'timeUnsynced': true,
      });

      expect(wired.timeUnsynced, isTrue);
      expect(mapped.timeUnsynced, isTrue);
    });

    test('a series without the flag reads as synced', () {
      final wired = LiveEnergyBucketsResult.fromWire(
        LiveEnergyBucketsWire(bucketMillis: 10000, buckets: const []),
      );
      final mapped = LiveEnergyBucketsResult.fromMap({
        'bucketMillis': 10000,
        'buckets': const [],
      });

      expect(wired.timeUnsynced, isFalse);
      expect(mapped.timeUnsynced, isFalse);
    });

    test('a window says how much of it was rebuilt, not whether it was', () {
      final window = EnergyWindowBucketsResult.fromWire(
        EnergyWindowBucketsWire(
          startUtcMillis: 1735689600000,
          endUtcMillis: 1735693200000,
          sessionCount: 4,
          resampledSessionCount: 1,
          buckets: [bucket(1735689600000)],
        ),
      );

      expect(window.sessionCount, 4);
      expect(window.resampledSessionCount, 1);
      expect(window.start.millisecondsSinceEpoch, 1735689600000);
      expect(window.end.millisecondsSinceEpoch, 1735693200000);
    });
  });

  group('range estimate', () {
    RangeEstimateWire usable() => RangeEstimateWire(
      timestampMillis: 1735689600000,
      carRangeQuality: 'AVAILABLE',
      carRangePropertyId: RangeEstimate.rangeRemainingPropertyId,
      capacityKwh: 39.6,
      capacitySource: 'SETTINGS',
      efficiencyTripCount: 11,
      ownRangeQuality: 'AVAILABLE',
      carRangeKm: 210,
      carRangeSignalSource: 'VHAL_CALLBACK',
      socPercent: 64.8,
      efficiencyKmPerKwh: 6.2,
      efficiencySource: 'CLOSED_TRIPS_7D',
      efficiencyWindowDays: 7,
      efficiencyDistanceKm: 412.5,
      efficiencyNetEnergyKwh: 66.5,
      fullRangeKm: 245.5,
      ownRangeKm: 159.1,
    );

    test('the wire and the map agree on a usable estimate', () {
      final wired = RangeEstimate.fromWire(usable());
      final mapped = RangeEstimate.fromMap({
        'timestampMillis': 1735689600000,
        'carRangeQuality': 'AVAILABLE',
        'carRangePropertyId': RangeEstimate.rangeRemainingPropertyId,
        'capacityKwh': 39.6,
        'capacitySource': 'SETTINGS',
        'efficiencyTripCount': 11,
        'ownRangeQuality': 'AVAILABLE',
        'carRangeKm': 210.0,
        'carRangeSignalSource': 'VHAL_CALLBACK',
        'socPercent': 64.8,
        'efficiencyKmPerKwh': 6.2,
        'efficiencySource': 'CLOSED_TRIPS_7D',
        'efficiencyWindowDays': 7,
        'efficiencyDistanceKm': 412.5,
        'efficiencyNetEnergyKwh': 66.5,
        'fullRangeKm': 245.5,
        'ownRangeKm': 159.1,
      });

      expect(wired.carRangeKm, mapped.carRangeKm);
      expect(wired.carRangeQuality, mapped.carRangeQuality);
      expect(wired.socPercent, mapped.socPercent);
      expect(wired.capacityKwh, mapped.capacityKwh);
      expect(wired.efficiencyKmPerKwh, mapped.efficiencyKmPerKwh);
      expect(wired.fullRangeKm, mapped.fullRangeKm);
      expect(wired.ownRangeKm, mapped.ownRangeKm);
      expect(wired.ownRangeQuality, 'AVAILABLE');
    });

    test('the typed path still refuses an implausible capacity', () {
      // Outside `minCapacityKwh`..`maxCapacityKwh`. This is the Dart gate; the
      // 150 kWh VHAL default sits inside that span and is refused natively, by
      // the null source timestamp. A generated class expresses neither, so
      // both gates have to survive the migration.
      final estimate = RangeEstimate.fromWire(usable()..capacityKwh = 250);

      expect(estimate.capacityKwh, 0);
      expect(estimate.ownRangeKm, isNull);
      expect(estimate.ownRangeQuality, 'UNAVAILABLE');
    });

    test('the typed path still refuses a capacity with no named source', () {
      final estimate = RangeEstimate.fromWire(
        usable()..capacitySource = 'GUESSED',
      );

      expect(estimate.capacityKwh, 0);
      expect(estimate.capacitySource, isEmpty);
      expect(estimate.ownRangeKm, isNull);
    });

    test('the typed path still refuses a source it does not recognise', () {
      final estimate = RangeEstimate.fromWire(
        usable()..carRangeSignalSource = 'GUESSED',
      );

      expect(estimate.carRangeKm, isNull);
      expect(estimate.carRangeQuality, 'UNAVAILABLE');
      expect(estimate.carRangeSignalSource, isNull);
    });

    test('the typed path still refuses the wrong property', () {
      final estimate = RangeEstimate.fromWire(
        usable()..carRangePropertyId = 0x11400309,
      );

      expect(estimate.carRangeKm, isNull);
      expect(estimate.carRangeQuality, 'UNAVAILABLE');
    });
  });

  group('session rows', () {
    test('a trip row carries every column the list draws', () {
      final wired = TripSessionSummary.fromWire(
        TripSessionWire(
          id: 'trip-1',
          status: 'ENDED',
          startedAtUtcMillis: 1735689600000,
          startedAtElapsedNanos: 1000000000,
          createdAtUtcMillis: 1735689600000,
          updatedAtUtcMillis: 1735690800000,
          movementStartedAtUtcMillis: 1735689660000,
          movementStartedAtElapsedNanos: 1060000000,
          endedAtUtcMillis: 1735690800000,
          endedAtElapsedNanos: 1200000000000,
          durationMillis: 1200000,
          startSoc: 74,
          endSoc: 69,
          startOdometerKm: 12800,
          endOdometerKm: 12812.4,
          startGear: 8,
          endReason: 'VEHICLE_IDLE',
          capacityWh: 39600,
        ),
      );
      final mapped = TripSessionSummary.fromMap(const {
        'id': 'trip-1',
        'status': 'ENDED',
        'startedAtUtcMillis': 1735689600000,
        'startedAtElapsedNanos': 1000000000,
        'createdAtUtcMillis': 1735689600000,
        'updatedAtUtcMillis': 1735690800000,
        'movementStartedAtUtcMillis': 1735689660000,
        'movementStartedAtElapsedNanos': 1060000000,
        'endedAtUtcMillis': 1735690800000,
        'endedAtElapsedNanos': 1200000000000,
        'durationMillis': 1200000,
        'startSoc': 74.0,
        'endSoc': 69.0,
        'startOdometerKm': 12800.0,
        'endOdometerKm': 12812.4,
        'startGear': 8,
        'endReason': 'VEHICLE_IDLE',
        'capacityWh': 39600.0,
      });

      expect(wired.id, mapped.id);
      expect(wired.status, mapped.status);
      expect(wired.durationMillis, mapped.durationMillis);
      expect(wired.startSoc, mapped.startSoc);
      expect(wired.endSoc, mapped.endSoc);
      expect(wired.startOdometerKm, mapped.startOdometerKm);
      expect(wired.endOdometerKm, mapped.endOdometerKm);
      expect(wired.startGear, mapped.startGear);
      expect(wired.endReason, mapped.endReason);
      expect(wired.capacityWh, mapped.capacityWh);
      expect(wired.updatedAtUtcMillis, mapped.updatedAtUtcMillis);
    });

    test('a charge row keeps its currency default when the column is null', () {
      final wired = ChargeSessionSummary.fromWire(
        ChargeSessionWire(
          id: 'charge-1',
          status: 'ENDED',
          plugConnectedAtUtcMillis: 1735689600000,
          plugConnectedAtElapsedNanos: 1000000000,
          createdAtUtcMillis: 1735689600000,
          updatedAtUtcMillis: 1735690800000,
          plugType: 2,
          estimatedEnergyKwh: 12.5,
        ),
      );

      // The database column is nullable and the app has a default; a null must
      // not reach the screen as an empty currency beside a real amount.
      expect(wired.costCurrency, 'BRL');
      expect(wired.plugType, 2);
      expect(wired.estimatedEnergyKwh, 12.5);
    });

    test('a merge candidate carries the breaks that justify it', () {
      final candidate = ChargeMergeCandidate.fromWire(
        ChargeMergeCandidateWire(
          sessionIds: const ['charge-1', 'charge-2'],
          sessions: [
            ChargeSessionWire(
              id: 'charge-1',
              status: 'ENDED',
              plugConnectedAtUtcMillis: 1735689600000,
              plugConnectedAtElapsedNanos: 1000000000,
              createdAtUtcMillis: 1735689600000,
              updatedAtUtcMillis: 1735690800000,
            ),
          ],
          breaks: [
            ChargeMergeBreakWire(
              previousSessionId: 'charge-1',
              nextSessionId: 'charge-2',
              gapMillis: 45000,
              socDelta: 0.5,
              odometerDeltaKm: 0,
            ),
          ],
          startUtcMillis: 1735689600000,
          endUtcMillis: 1735696800000,
          durationMillis: 7200000,
          totalFrames: 4210,
          startSoc: 20,
          endSoc: 80,
        ),
      );

      expect(candidate.sessionIds, ['charge-1', 'charge-2']);
      expect(candidate.breaks.single.gapMillis, 45000);
      expect(candidate.breaks.single.socDelta, 0.5);
      expect(candidate.totalFrames, 4210);
    });

    test('a refused merge says why, and claims nothing was changed', () {
      final result = ChargeMergeResult.fromWire(
        ChargeMergeResultWire(
          ok: false,
          mergedCount: 0,
          framesReassigned: 0,
          deletedSessions: 0,
          error: 'candidate_no_longer_valid',
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error, 'candidate_no_longer_valid');
      expect(result.deletedSessions, 0);
      expect(result.mergedSessionId, isNull);
    });

    test('a cost update answers the stored row, not the request', () {
      final result = ChargeSessionCostUpdateResult.fromWire(
        ChargeSessionCostUpdateWire(
          ok: true,
          updatedRows: 1,
          session: ChargeSessionWire(
            id: 'charge-1',
            status: 'ENDED',
            plugConnectedAtUtcMillis: 1735689600000,
            plugConnectedAtElapsedNanos: 1000000000,
            createdAtUtcMillis: 1735689600000,
            updatedAtUtcMillis: 1735690800000,
            costPerKwh: 0.92,
            costCurrency: 'BRL',
          ),
        ),
      );

      expect(result.ok, isTrue);
      expect(result.updatedRows, 1);
      expect(result.session!.costPerKwh, 0.92);
      expect(result.session!.costCurrency, 'BRL');
    });

    test('a failed cost update carries no row to show', () {
      final result = ChargeSessionCostUpdateResult.fromWire(
        ChargeSessionCostUpdateWire(ok: false, updatedRows: 0),
      );

      expect(result.ok, isFalse);
      expect(result.session, isNull);
    });
  });
}
