import 'package:flutter/foundation.dart';

/// How much a number may be trusted.
///
/// The four states are not a scale from good to bad. They are four different
/// facts about the source, and two of them print nothing while meaning opposite
/// things — the same distinction `EfficiencyState` already draws between a car
/// stopped at a red light and a bus that stopped publishing.
enum MeasurementValidity {
  /// The source published the value and the scale that turns it into a unit.
  measured,

  /// The value rests on an assumed scale or an assumed zero. It is printable,
  /// but never as a plain measurement: [Measurement.needsEstimateBadge] is the
  /// rule, not a reviewer's memory.
  estimated,

  /// The source published the value and marked it untrustworthy — a `*Invalid`
  /// companion bit on the bus, or a read the vehicle rejected.
  invalid,

  /// The source published nothing usable: the signal is absent from the
  /// negotiated schema, or its last sample is too old to describe now.
  unreported,
}

/// A number and the reason it may or may not be shown, travelling together.
///
/// The app used to carry these apart — `packCurrentA` beside
/// `packCurrentIsCalibrated`, a value beside its `*Invalid` bit, a reading
/// beside an `ok` flag — and every consumer re-decided what "trustworthy"
/// meant. Five call sites on two live screens each had to remember to consult
/// the companion boolean before printing. One of them forgetting is a plain
/// number on a driving surface that nothing measured.
///
/// Pairing them removes the chance to forget: there is no way to reach the
/// value without passing through the validity.
@immutable
class Measurement {
  const Measurement._(this.value, this.unit, this.validity, this.note);

  /// The source published both the value and its scale.
  const Measurement.measured(double value, {required String unit})
    : this._(value, unit, MeasurementValidity.measured, '');

  /// The value rests on an assumption, named in [note].
  ///
  /// [note] is required because an estimate the app cannot explain is one it
  /// should not print.
  const Measurement.estimated(
    double value, {
    required String unit,
    required String note,
  }) : this._(value, unit, MeasurementValidity.estimated, note);

  /// The source published the value and said not to trust it.
  const Measurement.invalid({required String unit, String note = ''})
    : this._(null, unit, MeasurementValidity.invalid, note);

  /// The source published nothing usable.
  const Measurement.unreported({required String unit, String note = ''})
    : this._(null, unit, MeasurementValidity.unreported, note);

  /// The raw number, present for [MeasurementValidity.measured] and
  /// [MeasurementValidity.estimated] only.
  ///
  /// Prefer [displayValue] when the number is going to a screen.
  final double? value;

  final String unit;
  final MeasurementValidity validity;

  /// Why the value is estimated, or why it was refused. Empty for a plain
  /// measurement.
  final String note;

  /// The number a surface may print, or null when it must print nothing.
  ///
  /// Identical to [value] today. It exists as a separate name so a screen reads
  /// the intent rather than the field, and so a future validity that carries a
  /// value it must not show cannot silently reach a display.
  double? get displayValue => switch (validity) {
    MeasurementValidity.measured || MeasurementValidity.estimated => value,
    MeasurementValidity.invalid || MeasurementValidity.unreported => null,
  };

  bool get hasValue => displayValue != null;

  /// True when the surface must mark the number as an estimate.
  bool get needsEstimateBadge => validity == MeasurementValidity.estimated;

  /// True when the source stands behind the number.
  bool get isMeasured => validity == MeasurementValidity.measured;

  /// Applies [transform] and keeps the validity.
  ///
  /// Use it for a unit change or a sign flip — anything that rewrites one
  /// number without adding a second source of doubt.
  Measurement map(double Function(double value) transform, {String? unit}) {
    final current = value;
    if (current == null) {
      return Measurement._(null, unit ?? this.unit, validity, note);
    }
    return Measurement._(transform(current), unit ?? this.unit, validity, note);
  }

  /// Combines two measurements into a derived one.
  ///
  /// The result takes the weaker of the two validities, because a quantity
  /// computed from an estimate is an estimate, and one computed from anything
  /// unusable is unusable. Pack power is the case that motivates it: V x I is
  /// a measurement only when both operands are.
  static Measurement combine(
    Measurement a,
    Measurement b, {
    required String unit,
    required double Function(double a, double b) compute,
  }) {
    final validity = _weaker(a.validity, b.validity);
    final left = a.value;
    final right = b.value;
    if (left == null || right == null) {
      return Measurement._(null, unit, validity, _firstNote(a, b));
    }
    return Measurement._(
      compute(left, right),
      unit,
      validity,
      validity == MeasurementValidity.estimated ? _firstNote(a, b) : '',
    );
  }

  /// Order of doubt, weakest last. `unreported` sits beyond `invalid` because a
  /// source that said nothing gives less than one that said "do not trust this".
  static const List<MeasurementValidity> _order = [
    MeasurementValidity.measured,
    MeasurementValidity.estimated,
    MeasurementValidity.invalid,
    MeasurementValidity.unreported,
  ];

  static MeasurementValidity _weaker(
    MeasurementValidity a,
    MeasurementValidity b,
  ) => _order.indexOf(a) >= _order.indexOf(b) ? a : b;

  static String _firstNote(Measurement a, Measurement b) =>
      a.note.isNotEmpty ? a.note : b.note;

  @override
  bool operator ==(Object other) =>
      other is Measurement &&
      other.value == value &&
      other.unit == unit &&
      other.validity == validity &&
      other.note == note;

  @override
  int get hashCode => Object.hash(value, unit, validity, note);

  @override
  String toString() =>
      'Measurement(${displayValue ?? '--'} $unit, ${validity.name}'
      '${note.isEmpty ? '' : ', $note'})';
}
