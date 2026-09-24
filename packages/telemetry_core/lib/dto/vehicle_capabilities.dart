part of 'telemetry_dto.dart';

/// What the vehicle can do, as opposed to what it is measuring now.
///
/// The car states this once, from its vehicle profile. It is not a status: a
/// capability does not come and go, and a surface that disappeared mid drive
/// would be a fault report rather than a description of the vehicle.
///
/// An unknown name is **kept**, not dropped. This side ships against one
/// profile and the car may ship against a newer one, so a name this build does
/// not recognise still tells the reader that the vehicle claimed something.
/// Dropping the whole answer over one unknown name is the 2026-08-15
/// range-estimate defect, where an unknown capacity-source name discarded a
/// complete estimate while the mock and the tests passed because they spelled
/// the name themselves.
@immutable
class VehicleCapabilities {
  const VehicleCapabilities({required this.profileId, required this.names});

  /// Every capability this build knows how to act on.
  static const knownNames = <String>{
    'BUS_RATE_TRANSPORT',
    'MEASURED_PACK_POWER',
    'CLIMATE_CONTROL',
    'PHONE_PROJECTION',
    'LOCATION',
  };

  /// Which profile answered. A diagnostic, never a vehicle identity.
  final String profileId;

  /// The capability names the car reported, unknown ones included.
  final Set<String> names;

  /// A vehicle that reported nothing, which is what a car with no profile says.
  static const empty = VehicleCapabilities(profileId: '', names: <String>{});

  bool has(String name) => names.contains(name);

  bool get hasBusRateTransport => has('BUS_RATE_TRANSPORT');
  bool get hasMeasuredPackPower => has('MEASURED_PACK_POWER');
  bool get hasClimateControl => has('CLIMATE_CONTROL');
  bool get hasPhoneProjection => has('PHONE_PROJECTION');
  bool get hasLocation => has('LOCATION');

  /// The names the car reported that this build cannot act on.
  Set<String> get unknownNames => names.difference(knownNames);

  factory VehicleCapabilities.fromMap(Map<String, dynamic> map) {
    final raw = map['capabilities'];
    final names = raw is List
        ? raw.whereType<String>().where((name) => name.isNotEmpty).toSet()
        : <String>{};
    return VehicleCapabilities(
      profileId: map['profileId'] as String? ?? '',
      names: names,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VehicleCapabilities &&
      other.profileId == profileId &&
      setEquals(other.names, names);

  @override
  int get hashCode => Object.hash(profileId, Object.hashAllUnordered(names));

  @override
  String toString() =>
      'VehicleCapabilities($profileId, ${names.toList()..sort()})';
}
