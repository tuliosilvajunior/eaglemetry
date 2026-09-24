import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

InsightSupport _support([
  int considered = 0,
  Duration window = kInsightOwnAverageWindow,
]) =>
    InsightSupport(window: window, considered: considered, excluded: const {});

void main() {
  group('insightPhrase - Absences', () {
    test('InsightAbsence.subjectNeverRecorded yields subjectUnusable', () {
      final read = InsightRead.none(
        absence: InsightAbsence.subjectNeverRecorded,
        support: _support(0),
      );
      expect(insightPhrase(read), const InsightPhrase.subjectUnusable());
    });

    test('InsightAbsence.subjectNoMinuteBuckets yields subjectUnusable', () {
      final read = InsightRead.none(
        absence: InsightAbsence.subjectNoMinuteBuckets,
        support: _support(0),
      );
      expect(insightPhrase(read), const InsightPhrase.subjectUnusable());
    });

    test('InsightAbsence.subjectSignContradiction yields subjectUnusable', () {
      final read = InsightRead.none(
        absence: InsightAbsence.subjectSignContradiction,
        support: _support(0),
      );
      expect(insightPhrase(read), const InsightPhrase.subjectUnusable());
    });

    test('InsightAbsence.subjectUnconfirmedSign yields subjectUnusable', () {
      final read = InsightRead.none(
        absence: InsightAbsence.subjectUnconfirmedSign,
        support: _support(0),
      );
      expect(insightPhrase(read), const InsightPhrase.subjectUnusable());
    });

    test('InsightAbsence.subjectTooShort yields subjectUnusable', () {
      final read = InsightRead.none(
        absence: InsightAbsence.subjectTooShort,
        support: _support(0),
      );
      expect(insightPhrase(read), const InsightPhrase.subjectUnusable());
    });

    test('InsightAbsence.subjectNotClosed yields subjectUnusable', () {
      final read = InsightRead.none(
        absence: InsightAbsence.subjectNotClosed,
        support: _support(0),
      );
      expect(insightPhrase(read), const InsightPhrase.subjectUnusable());
    });

    test(
      'InsightAbsence.insufficientSupport without placeName yields notEnoughData',
      () {
        final read = InsightRead.none(
          absence: InsightAbsence.insufficientSupport,
          support: _support(3),
        );
        expect(insightPhrase(read), const InsightPhrase.notEnoughData(3));
      },
    );

    test(
      'InsightAbsence.insufficientSupport with placeName and route window yields variantNotEnough',
      () {
        final read = InsightRead.none(
          absence: InsightAbsence.insufficientSupport,
          support: _support(2, kInsightRouteWindow),
        );
        expect(
          insightPhrase(read, placeName: 'Work'),
          const InsightPhrase.variantNotEnough(2),
        );
      },
    );

    test('InsightAbsence.notOnRoute yields variantNotEnough', () {
      final read = InsightRead.none(
        absence: InsightAbsence.notOnRoute,
        support: _support(1, kInsightRouteWindow),
      );
      expect(
        insightPhrase(read, placeName: 'Home'),
        const InsightPhrase.variantNotEnough(1),
      );
      expect(insightPhrase(read), const InsightPhrase.variantNotEnough(1));
    });

    test('InsightAbsence.noOtherVariant yields variantNotEnough', () {
      final read = InsightRead.none(
        absence: InsightAbsence.noOtherVariant,
        support: _support(5, kInsightRouteWindow),
      );
      expect(
        insightPhrase(read, placeName: 'Home'),
        const InsightPhrase.variantNotEnough(5),
      );
      expect(insightPhrase(read), const InsightPhrase.variantNotEnough(5));
    });

    test('null absence without insight yields subjectUnusable', () {
      // Direct construction of InsightRead with null absence
      final read = InsightRead.none(
        absence: InsightAbsence.subjectNeverRecorded,
        support: _support(0),
      );
      expect(insightPhrase(read), const InsightPhrase.subjectUnusable());
    });

    test(
      'subjectNeverRecorded with placeName still yields subjectUnusable',
      () {
        final read = InsightRead.none(
          absence: InsightAbsence.subjectNeverRecorded,
          support: _support(0, kInsightRouteWindow),
        );
        expect(
          insightPhrase(read, placeName: 'Work'),
          const InsightPhrase.subjectUnusable(),
        );
      },
    );
  });

  group('insightPhrase - Confidences and Claims', () {
    test(
      'tripVsOwnAverage30d with notDistinguishable yields notDistinguishable',
      () {
        final read = InsightRead.present(
          Insight(
            claim: InsightClaim.tripVsOwnAverage30d,
            magnitude: const Measurement.measured(-10.0, unit: 'Wh/km'),
            subject: const Measurement.measured(100.0, unit: 'Wh/km'),
            reference: const Measurement.measured(110.0, unit: 'Wh/km'),
            baseline: InsightBaseline.ownAverage30d,
            support: _support(8),
            aggregationVersion: 1,
            confidence: InsightConfidence.notDistinguishable,
          ),
        );
        expect(insightPhrase(read), const InsightPhrase.notDistinguishable(8));
      },
    );

    test('tripVsOwnAverage30d supported with negative gap yields usedLess', () {
      final read = InsightRead.present(
        Insight(
          claim: InsightClaim.tripVsOwnAverage30d,
          magnitude: const Measurement.measured(-75.0, unit: 'Wh/km'),
          subject: const Measurement.measured(50.0, unit: 'Wh/km'),
          reference: const Measurement.measured(125.0, unit: 'Wh/km'),
          baseline: InsightBaseline.ownAverage30d,
          support: _support(8),
          aggregationVersion: 1,
          confidence: InsightConfidence.supported,
        ),
      );
      expect(insightPhrase(read), const InsightPhrase.usedLess('75.0', 8));
    });

    test('tripVsOwnAverage30d supported with positive gap yields usedMore', () {
      final read = InsightRead.present(
        Insight(
          claim: InsightClaim.tripVsOwnAverage30d,
          magnitude: const Measurement.measured(32.45, unit: 'Wh/km'),
          subject: const Measurement.measured(152.45, unit: 'Wh/km'),
          reference: const Measurement.measured(120.0, unit: 'Wh/km'),
          baseline: InsightBaseline.ownAverage30d,
          support: _support(12),
          aggregationVersion: 1,
          confidence: InsightConfidence.supported,
        ),
      );
      expect(insightPhrase(read), const InsightPhrase.usedMore('32.5', 12));
    });

    test(
      'variantVsVariant with notDistinguishable yields variantNotDistinguishable',
      () {
        final read = InsightRead.present(
          Insight(
            claim: InsightClaim.variantVsVariant,
            magnitude: const Measurement.measured(5.0, unit: 'Wh/km'),
            subject: const Measurement.measured(125.0, unit: 'Wh/km'),
            reference: const Measurement.measured(120.0, unit: 'Wh/km'),
            baseline: InsightBaseline.otherVariantSameRoute,
            support: _support(6, kInsightRouteWindow),
            aggregationVersion: 1,
            confidence: InsightConfidence.notDistinguishable,
          ),
        );
        expect(
          insightPhrase(read, placeName: 'Work'),
          const InsightPhrase.variantNotDistinguishable('Work', 6),
        );
      },
    );

    test(
      'variantVsVariant supported with negative gap yields variantUsedLess',
      () {
        final read = InsightRead.present(
          Insight(
            claim: InsightClaim.variantVsVariant,
            magnitude: const Measurement.measured(-60.0, unit: 'Wh/km'),
            subject: const Measurement.measured(80.0, unit: 'Wh/km'),
            reference: const Measurement.measured(140.0, unit: 'Wh/km'),
            baseline: InsightBaseline.otherVariantSameRoute,
            support: _support(4, kInsightRouteWindow),
            aggregationVersion: 1,
            confidence: InsightConfidence.supported,
          ),
        );
        expect(
          insightPhrase(read, placeName: 'Work'),
          const InsightPhrase.variantUsedLess('60.0', 'Work', 4),
        );
      },
    );

    test(
      'variantVsVariant supported with positive gap yields variantUsedMore',
      () {
        final read = InsightRead.present(
          Insight(
            claim: InsightClaim.variantVsVariant,
            magnitude: const Measurement.measured(42.0, unit: 'Wh/km'),
            subject: const Measurement.measured(142.0, unit: 'Wh/km'),
            reference: const Measurement.measured(100.0, unit: 'Wh/km'),
            baseline: InsightBaseline.otherVariantSameRoute,
            support: _support(4, kInsightRouteWindow),
            aggregationVersion: 1,
            confidence: InsightConfidence.supported,
          ),
        );
        expect(
          insightPhrase(read, placeName: 'Casa'),
          const InsightPhrase.variantUsedMore('42.0', 'Casa', 4),
        );
      },
    );

    test('magnitude with null displayValue yields subjectUnusable', () {
      final read = InsightRead.present(
        Insight(
          claim: InsightClaim.tripVsOwnAverage30d,
          magnitude: const Measurement.invalid(unit: 'Wh/km'),
          subject: const Measurement.measured(50.0, unit: 'Wh/km'),
          reference: const Measurement.measured(125.0, unit: 'Wh/km'),
          baseline: InsightBaseline.ownAverage30d,
          support: _support(8),
          aggregationVersion: 1,
          confidence: InsightConfidence.supported,
        ),
      );
      expect(insightPhrase(read), const InsightPhrase.subjectUnusable());
    });
  });
}
