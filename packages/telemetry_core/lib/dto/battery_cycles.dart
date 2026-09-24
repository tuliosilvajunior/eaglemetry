part of 'telemetry_dto.dart';

/// One battery cycle: the distance and the money that one full battery bought.
///
/// A cycle closes when the SOC removed by trips reaches 100 %, which is the
/// equivalent full cycle. The fold is native; this is the domain type over that answer.
///
/// The derived readouts are getters rather than wire fields, and each of them
/// returns null instead of a number it cannot support. A cycle whose energy is
/// a floor has no efficiency, and a cycle fed by two currencies has no cost.
class BatteryCycleSummary {
  const BatteryCycleSummary({
    required this.ordinal,
    required this.startUtcMillis,
    required this.endUtcMillis,
    required this.dischargePercent,
    required this.distanceKm,
    required this.tripEnergyKwh,
    required this.parkedEnergyKwh,
    required this.parkedSocPercent,
    required this.pricedEnergyKwh,
    required this.unpricedEnergyKwh,
    required this.isOpen,
    required this.isPartial,
    required this.energyIncomplete,
    required this.mixedCurrency,
    required this.updatedAtUtcMillis,
    required this.cost,
    required this.costCurrency,
    required this.frozenAtUtcMillis,
  });

  factory BatteryCycleSummary.fromMap(Map<String, Object?> map) =>
      BatteryCycleSummary._raw(
        ordinal: _asInt(map['ordinal']) ?? 0,
        startUtcMillis: _asInt(map['startUtcMillis']) ?? 0,
        endUtcMillis: _asInt(map['endUtcMillis']) ?? 0,
        dischargePercent: _asDouble(map['dischargePercent']) ?? 0,
        distanceKm: _asDouble(map['distanceKm']) ?? 0,
        tripEnergyKwh: _asDouble(map['tripEnergyKwh']) ?? 0,
        parkedEnergyKwh: _asDouble(map['parkedEnergyKwh']) ?? 0,
        parkedSocPercent: _asDouble(map['parkedSocPercent']) ?? 0,
        pricedEnergyKwh: _asDouble(map['pricedEnergyKwh']) ?? 0,
        unpricedEnergyKwh: _asDouble(map['unpricedEnergyKwh']) ?? 0,
        isOpen: _asBool(map['isOpen'], orElse: false),
        isPartial: _asBool(map['isPartial'], orElse: false),
        energyIncomplete: _asBool(map['energyIncomplete'], orElse: false),
        mixedCurrency: _asBool(map['mixedCurrency'], orElse: false),
        updatedAtUtcMillis: _asInt(map['updatedAtUtcMillis']) ?? 0,
        cost: _asDouble(map['cost']),
        costCurrency: map['costCurrency'] as String?,
        frozenAtUtcMillis: _asInt(map['frozenAtUtcMillis']),
      );

  /// From the generated wire class.
  factory BatteryCycleSummary.fromWire(BatteryCycleWire wire) =>
      BatteryCycleSummary._raw(
        ordinal: wire.ordinal,
        startUtcMillis: wire.startUtcMillis,
        endUtcMillis: wire.endUtcMillis,
        dischargePercent: wire.dischargePercent,
        distanceKm: wire.distanceKm,
        tripEnergyKwh: wire.tripEnergyKwh,
        parkedEnergyKwh: wire.parkedEnergyKwh,
        parkedSocPercent: wire.parkedSocPercent,
        pricedEnergyKwh: wire.pricedEnergyKwh,
        unpricedEnergyKwh: wire.unpricedEnergyKwh,
        isOpen: wire.isOpen,
        isPartial: wire.isPartial,
        energyIncomplete: wire.energyIncomplete,
        mixedCurrency: wire.mixedCurrency,
        updatedAtUtcMillis: wire.updatedAtUtcMillis,
        cost: wire.cost,
        costCurrency: wire.costCurrency,
        frozenAtUtcMillis: wire.frozenAtUtcMillis,
      );

  /// The one gate both routes pass.
  ///
  /// A generated class cannot say that a negative distance is not a distance,
  /// or that a bar past 100 % is not a bar. The judgement lives here so it
  /// cannot be lost to a field being typed.
  factory BatteryCycleSummary._raw({
    required int ordinal,
    required int startUtcMillis,
    required int endUtcMillis,
    required double dischargePercent,
    required double distanceKm,
    required double tripEnergyKwh,
    required double parkedEnergyKwh,
    required double parkedSocPercent,
    required double pricedEnergyKwh,
    required double unpricedEnergyKwh,
    required bool isOpen,
    required bool isPartial,
    required bool energyIncomplete,
    required bool mixedCurrency,
    required int updatedAtUtcMillis,
    required double? cost,
    required String? costCurrency,
    required int? frozenAtUtcMillis,
  }) {
    return BatteryCycleSummary(
      ordinal: ordinal,
      startUtcMillis: startUtcMillis,
      endUtcMillis: endUtcMillis,
      dischargePercent: dischargePercent.clamp(0.0, 100.0).toDouble(),
      distanceKm: distanceKm.isFinite && distanceKm > 0 ? distanceKm : 0,
      tripEnergyKwh: tripEnergyKwh.isFinite && tripEnergyKwh > 0
          ? tripEnergyKwh
          : 0,
      parkedEnergyKwh: parkedEnergyKwh.isFinite && parkedEnergyKwh > 0
          ? parkedEnergyKwh
          : 0,
      parkedSocPercent: parkedSocPercent.isFinite && parkedSocPercent > 0
          ? parkedSocPercent
          : 0,
      pricedEnergyKwh: pricedEnergyKwh.isFinite && pricedEnergyKwh > 0
          ? pricedEnergyKwh
          : 0,
      unpricedEnergyKwh: unpricedEnergyKwh.isFinite && unpricedEnergyKwh > 0
          ? unpricedEnergyKwh
          : 0,
      isOpen: isOpen,
      isPartial: isPartial,
      energyIncomplete: energyIncomplete,
      mixedCurrency: mixedCurrency,
      updatedAtUtcMillis: updatedAtUtcMillis,
      // Two currencies in one cycle give no cost. The native ledger already
      // refuses it; the gate is repeated because the flag and the number must
      // never be read apart.
      cost: mixedCurrency ? null : _positiveOrNull(cost),
      costCurrency: mixedCurrency ? null : costCurrency,
      frozenAtUtcMillis: frozenAtUtcMillis,
    );
  }

  /// The identity, counting from 1 at the oldest cycle.
  final int ordinal;
  final int startUtcMillis;
  final int endUtcMillis;

  /// How full the bar is, 0 to 100. Below 100 only for the open cycle.
  final double dischargePercent;
  final double distanceKm;
  final double tripEnergyKwh;

  /// Counted against the money ledger, but it never moved the boundary.
  final double parkedEnergyKwh;
  final double parkedSocPercent;
  final double pricedEnergyKwh;
  final double unpricedEnergyKwh;
  final bool isOpen;

  /// Collection began in the middle of this battery, so it is not a whole one.
  final bool isPartial;

  /// Some interval had no trustworthy capacity, so the energy is a floor.
  final bool energyIncomplete;
  final bool mixedCurrency;
  final int updatedAtUtcMillis;
  final double? cost;
  final String? costCurrency;

  /// When the sessions behind this cycle were found to be gone. Its cost is
  /// then final rather than current.
  final int? frozenAtUtcMillis;

  bool get isFrozen => frozenAtUtcMillis != null;

  /// True when every interval of this cycle had a trustworthy capacity.
  ///
  /// Energy, efficiency and the cost per kWh are readable only then. A floor
  /// divided into a distance reports an efficiency the car never reached.
  bool get hasEnergy => !energyIncomplete && tripEnergyKwh > 0;

  /// The cost of the whole cycle, or null when part of it was never priced.
  ///
  /// [cost] is what the priced share cost. This is the figure a total may use,
  /// because a cost that silently omits unpriced energy reads as complete.
  double? get completeCost => costCoverage == 1.0 ? cost : null;

  double? get whPerKm =>
      hasEnergy && distanceKm > 0 ? tripEnergyKwh * 1000 / distanceKm : null;

  double? get kmPerKwh =>
      hasEnergy && distanceKm > 0 ? distanceKm / tripEnergyKwh : null;

  /// The weighted average price of the energy this cycle actually paid for.
  double? get averageCostPerKwh {
    final total = cost;
    if (total == null || pricedEnergyKwh <= 0) return null;
    return total / pricedEnergyKwh;
  }

  /// The priced share of the energy the cycle used, 0 to 1, or null when the
  /// cycle drew no energy at all.
  double? get costCoverage {
    final total = pricedEnergyKwh + unpricedEnergyKwh;
    if (total <= 0) return null;
    return (pricedEnergyKwh / total).clamp(0.0, 1.0).toDouble();
  }

  /// The kWh this cycle took out per 100 % of SOC.
  ///
  /// Tracked over months this is a state-of-health trend, measured from real
  /// use rather than declared by the car.
  double? get measuredCapacityKwh {
    if (!hasEnergy || dischargePercent <= 0) return null;
    return tripEnergyKwh * 100 / dischargePercent;
  }
}

/// A page of cycles, newest first.
class BatteryCyclesResult {
  const BatteryCyclesResult({
    required this.cycles,
    required this.totalCount,
    required this.limit,
  });

  factory BatteryCyclesResult.fromMap(Map<String, Object?> map) =>
      BatteryCyclesResult(
        cycles: List.unmodifiable(
          _asMapList(map['cycles']).map(BatteryCycleSummary.fromMap),
        ),
        totalCount: _asInt(map['totalCount']) ?? 0,
        limit: _asInt(map['limit']) ?? 0,
      );

  factory BatteryCyclesResult.fromWire(BatteryCyclesWire wire) =>
      BatteryCyclesResult(
        cycles: List.unmodifiable(
          wire.cycles.map(BatteryCycleSummary.fromWire),
        ),
        totalCount: wire.totalCount,
        limit: wire.limit,
      );

  final List<BatteryCycleSummary> cycles;
  final int totalCount;
  final int limit;

  /// The cycle in progress, or null when nothing is open.
  BatteryCycleSummary? get openCycle =>
      cycles.where((cycle) => cycle.isOpen).firstOrNull;
}

double? _positiveOrNull(double? value) {
  if (value == null || !value.isFinite || value < 0) return null;
  return value;
}

/// What kind of session one cycle member is.
enum BatteryCycleSessionKind { trip, charge, parked }

/// One session's part in one battery cycle.
///
/// The membership is written by the native fold, not recovered from the
/// timestamps: a trip that crosses the 100 % mark belongs to two cycles, and
/// [share] is how much of it this one took.
///
/// [trip] and [charge] are the session itself, when it still exists. A parked
/// session has no list row, so both are null for one and [deleted] is the only
/// thing to read.
class BatteryCycleSessionEntry {
  const BatteryCycleSessionEntry({
    required this.kind,
    required this.sessionId,
    required this.share,
    required this.startUtcMillis,
    required this.endUtcMillis,
    required this.deleted,
    required this.trip,
    required this.charge,
  });

  factory BatteryCycleSessionEntry.fromMap(Map<String, Object?> map) {
    final kind = switch (map['kind']) {
      'CHARGE' || 'charge' => BatteryCycleSessionKind.charge,
      'PARKED' || 'parked' => BatteryCycleSessionKind.parked,
      _ => BatteryCycleSessionKind.trip,
    };
    final trip = map['trip'];
    final charge = map['charge'];
    return BatteryCycleSessionEntry._raw(
      kind: kind,
      sessionId: map['sessionId'] as String? ?? '',
      share: _asDouble(map['share']) ?? 0,
      startUtcMillis: _asInt(map['startUtcMillis']) ?? 0,
      endUtcMillis: _asInt(map['endUtcMillis']) ?? 0,
      deleted: _asBool(map['deleted'], orElse: false),
      trip: trip is Map
          ? TripSessionSummary.fromMap(Map<String, Object?>.from(trip))
          : null,
      charge: charge is Map
          ? ChargeSessionSummary.fromMap(Map<String, Object?>.from(charge))
          : null,
    );
  }

  /// From the generated wire class.
  factory BatteryCycleSessionEntry.fromWire(BatteryCycleSessionWire wire) {
    final trip = wire.trip;
    final charge = wire.charge;
    return BatteryCycleSessionEntry._raw(
      kind: switch (wire.kind) {
        BatteryCycleSessionKindWire.trip => BatteryCycleSessionKind.trip,
        BatteryCycleSessionKindWire.charge => BatteryCycleSessionKind.charge,
        BatteryCycleSessionKindWire.parked => BatteryCycleSessionKind.parked,
      },
      sessionId: wire.sessionId,
      share: wire.share,
      startUtcMillis: wire.startUtcMillis,
      endUtcMillis: wire.endUtcMillis,
      deleted: wire.deleted,
      trip: trip == null ? null : TripSessionSummary.fromWire(trip),
      charge: charge == null ? null : ChargeSessionSummary.fromWire(charge),
    );
  }

  /// The gates both routes pass.
  ///
  /// A share outside 0 to 1 is not a share, and a member that arrived with its
  /// session cannot also be a deleted one. A generated class cannot say either.
  factory BatteryCycleSessionEntry._raw({
    required BatteryCycleSessionKind kind,
    required String sessionId,
    required double share,
    required int startUtcMillis,
    required int endUtcMillis,
    required bool deleted,
    required TripSessionSummary? trip,
    required ChargeSessionSummary? charge,
  }) {
    final resolved = trip != null || charge != null;
    return BatteryCycleSessionEntry(
      kind: kind,
      sessionId: sessionId,
      share: share.isFinite ? share.clamp(0.0, 1.0).toDouble() : 0,
      startUtcMillis: startUtcMillis,
      endUtcMillis: endUtcMillis,
      deleted: deleted && !resolved,
      // A session of one kind cannot be carried as the other.
      trip: kind == BatteryCycleSessionKind.trip ? trip : null,
      charge: kind == BatteryCycleSessionKind.charge ? charge : null,
    );
  }

  final BatteryCycleSessionKind kind;
  final String sessionId;

  /// How much of the session this cycle took, 0 to 1. Below 1 only for a trip
  /// split across a cycle boundary.
  final double share;

  /// The session's own window, copied when the cycle was folded. It is what is
  /// left when the session itself is deleted.
  final int startUtcMillis;
  final int endUtcMillis;

  /// Retention deleted the session and the cycle outlived it. The member stays,
  /// because it is part of what the cycle counted.
  final bool deleted;

  final TripSessionSummary? trip;
  final ChargeSessionSummary? charge;

  /// The cycle took only part of this session, because it closed inside it.
  bool get isSplit => share < 1;

  /// Whether the session behind this member can still be opened.
  bool get isReadable => trip != null || charge != null;
}

/// What one cycle is made of, oldest session first.
class BatteryCycleSessionsResult {
  const BatteryCycleSessionsResult({
    required this.ordinal,
    required this.sessions,
  });

  factory BatteryCycleSessionsResult.fromMap(Map<String, Object?> map) =>
      BatteryCycleSessionsResult(
        ordinal: _asInt(map['ordinal']) ?? 0,
        sessions: List.unmodifiable(
          _asMapList(map['sessions']).map(BatteryCycleSessionEntry.fromMap),
        ),
      );

  factory BatteryCycleSessionsResult.fromWire(BatteryCycleSessionsWire wire) =>
      BatteryCycleSessionsResult(
        ordinal: wire.ordinal,
        sessions: List.unmodifiable(
          wire.sessions.map(BatteryCycleSessionEntry.fromWire),
        ),
      );

  final int ordinal;

  /// Oldest first. Empty for a frozen cycle: its sessions were deleted before
  /// the membership was recorded, and nothing can reconstruct them.
  final List<BatteryCycleSessionEntry> sessions;

  /// True when retention has taken part of what this cycle counted. A reader
  /// must say so rather than show the survivors as the whole list.
  bool get hasDeletedSessions => sessions.any((entry) => entry.deleted);
}
