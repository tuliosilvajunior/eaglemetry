import 'package:flutter/material.dart';
import 'package:capy_ui/capy_ui.dart';

import '../../core/range_drop_controller.dart';
import '../../core/telemetry_format.dart';
import '../../l10n/app_localizations.dart';

/// The `Range drop` card: how much promised range each source spends per
/// kilometre actually driven.
///
/// It draws three raw quantities and nothing else — no ratio, no percentage,
/// no winner. The comparison is the reader's to make, and a card that stated a
/// verdict would be wrong on every stretch where the car is the closer of the
/// two.
///
/// It holds no arithmetic. Everything it prints comes from [RangeDropState],
/// which is where the baseline, the floor and the frozen stretch are decided.
class RangeDropPanel extends StatelessWidget {
  const RangeDropPanel({required this.state, super.key});

  final RangeDropState state;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return AppCard(title: loc.rangeDropTitle, child: _body(context, loc));
  }

  Widget _body(BuildContext context, AppLocalizations loc) {
    final colors = AppThemeColors.of(context);
    if (!state.hasBaseline) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          loc.rangeDropWaiting,
          style: AppText.body.copyWith(color: colors.inkMuted),
        ),
      );
    }
    // Below the floor the stretch is still drawn, with the two drops struck out
    // as unreadable. Replacing the card with a sentence would take the distance
    // off the screen as well, and the distance is measured either way.
    final tooShort = !state.floorCleared;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Row(
          label: loc.rangeDropDistance,
          value: distanceLabelFor(state.distanceKm, loc),
        ),
        const SizedBox(height: AppSpacing.x4),
        _Row(
          label: state.car.isGain
              ? loc.rangeDropCarGained
              : loc.rangeDropCarSpent,
          value: _drop(state.car, loc, muted: tooShort),
          note: tooShort ? loc.rangeDropTooShort : _reason(state.car, loc),
        ),
        const SizedBox(height: AppSpacing.x4),
        _Row(
          label: state.app.isGain
              ? loc.rangeDropAppGained
              : loc.rangeDropAppSpent,
          value: _drop(state.app, loc, muted: tooShort),
          note: tooShort ? null : _reason(state.app, loc),
        ),
        const SizedBox(height: AppSpacing.x5),
        Text(
          _caption(loc),
          style: AppText.caption.copyWith(color: colors.inkSubtle),
        ),
      ],
    );
  }

  /// A recovered drop is printed by its magnitude: the verb beside it has
  /// already said which way it went, and `gained -3 km` reads as a loss.
  String _drop(
    RangeDropLine line,
    AppLocalizations loc, {
    required bool muted,
  }) {
    final km = line.km;
    if (muted || km == null) return '--';
    return distanceLabelFor(km.abs(), loc);
  }

  /// The native reason code in the reader's language.
  ///
  /// An unknown code is dropped rather than printed raw: this card is read
  /// while driving, and a bare `UNPUBLISHED_SIGNAL` says nothing to the person
  /// reading it.
  String? _reason(RangeDropLine line, AppLocalizations loc) =>
      switch (line.reason) {
        'COLLECTION_STOPPED' => loc.rangeReasonCollectionStopped,
        'WAITING_FOR_SIGNAL' => loc.rangeReasonWaitingForSignal,
        'SIGNAL_ERROR' => loc.rangeReasonSignalError,
        'UNPUBLISHED_SIGNAL' => loc.rangeReasonUnpublishedSignal,
        'OUT_OF_RANGE' => loc.rangeReasonOutOfRange,
        'EFFICIENCY_LOADING' => loc.rangeReasonEfficiencyLoading,
        'NO_VALID_EFFICIENCY' => loc.rangeReasonNoValidEfficiency,
        'EFFICIENCY_REFRESH_FAILED' => loc.rangeReasonEfficiencyStale,
        _ => null,
      };

  /// Which stretch the figures cover.
  ///
  /// Never omitted. The stretch is only the whole trip when the app was already
  /// watching when the trip began, and a card that did not say so would read as
  /// a claim about a drive it never measured.
  String _caption(AppLocalizations loc) {
    final at = state.baselineAt;
    final since = at == null
        ? ''
        : loc.rangeDropStretch('${twoDigits(at.hour)}:${twoDigits(at.minute)}');
    if (!state.frozen) return since;
    return '${loc.rangeDropFrozen} · $since';
  }
}

/// One labelled quantity, with its explanation under it when there is one.
///
/// The label wraps and the value scales down instead of clipping: this is the
/// leading column of the dashboard, which is about 220 px at the design
/// system's 960 px floor, and the longest of the localized labels does not fit
/// one line there.
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.note});

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final note = this.note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppText.label.copyWith(color: colors.inkMuted),
          maxLines: 2,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: AppText.metricMd, maxLines: 1),
          ),
        ),
        if (note != null)
          Text(
            note,
            style: AppText.caption.copyWith(color: colors.inkSubtle),
            maxLines: 2,
          ),
      ],
    );
  }
}
