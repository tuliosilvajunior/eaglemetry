import 'package:flutter/material.dart';

import '../../core/telemetry_api.dart';
import '../../core/telemetry_format.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'history_detail_page.dart';

/// What one battery ran, oldest first.
///
/// The order is the point: a battery is not a list of records, it is a stretch
/// of the car's life, and reading it forwards is what makes the charges and the
/// drives between them a story rather than a table.
///
/// This is the one detail card that scrolls. A battery holds as many sessions
/// as it took to spend it, which is a number nothing here controls, and a wall
/// that dropped the overflow would lose exactly the part the reader scrolled
/// for. The stage's drag-to-close still works on the header above the list,
/// which is where the hint sits.
class CycleTimelineCard extends StatelessWidget {
  const CycleTimelineCard({required this.page, super.key});

  final HistoryCycleDetailPage page;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final cycle = page.cycle;
    final sessions = page.sessions.sessions;

    return AppCard(
      title: page.title(context),
      subtitle: loc.v2HistoryCollapseHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CycleBar(
            fillPercent: cycle.dischargePercent,
            leadingLabel: loc.v2CycleOrdinal(cycle.ordinal),
            valueLabel: cycle.dischargePercent.toStringAsFixed(0),
            valueUnit: loc.unitPercent,
            isPartial: cycle.isPartial,
            semanticsLabel: loc.v2CycleSemantics(
              cycle.ordinal,
              cycle.dischargePercent.toStringAsFixed(0),
            ),
          ),
          const SizedBox(height: AppSpacing.x4),
          Row(
            children: [
              Expanded(
                child: Text(
                  loc.v2CycleTimelineTitle,
                  style: AppText.bodyStrong.copyWith(color: colors.ink),
                ),
              ),
              Text(
                '${sessions.length}',
                style: AppText.label.copyWith(color: colors.inkSubtle),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          if (sessions.isEmpty)
            // A frozen battery. Its sessions were deleted before the app
            // recorded what they were, and nothing can reconstruct them.
            Expanded(
              child: Text(
                loc.v2CycleTimelineEmpty,
                style: AppText.body.copyWith(color: colors.inkSubtle),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: sessions.length,
                itemBuilder: (context, index) =>
                    _CycleTimelineRow(entry: sessions[index]),
              ),
            ),
        ],
      ),
    );
  }
}

/// One thing that happened inside a battery.
class _CycleTimelineRow extends StatelessWidget {
  const _CycleTimelineRow({required this.entry});

  final BatteryCycleSessionEntry entry;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final started = dateTimeFromMillis(entry.startUtcMillis);
    // A deleted session keeps its place and its clock, and everything it said
    // about itself is gone. Printing it dimmed is the honest half-answer:
    // dropping the row would make a part of the battery unaccounted for.
    final ink = entry.deleted ? colors.inkSubtle : colors.ink;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x2),
      child: Material(
        color: colors.control,
        borderRadius: AppRadii.mdRadius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x4,
              vertical: AppSpacing.x3,
            ),
            child: Row(
              children: [
                Icon(_icon, size: AppSizes.iconSm, color: _accent(colors)),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        started == null
                            ? '--'
                            : formatTripListDateTime(started),
                        style: AppText.bodyStrong.copyWith(color: ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _kindLabel(loc),
                        style: AppText.label.copyWith(color: colors.inkSubtle),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // The share, and only when it is one. A whole session says
                // nothing here, because whole is what a session normally is.
                if (entry.isSplit) ...[
                  _TimelineChip(
                    label: loc.v2CycleTimelineShare(
                      (entry.share * 100).toStringAsFixed(0),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x3),
                ],
                for (final fact in _facts(loc))
                  Expanded(
                    flex: 2,
                    child: Text(
                      fact,
                      style: AppText.body.copyWith(color: ink),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData get _icon => switch (entry.kind) {
    BatteryCycleSessionKind.trip => Icons.route,
    BatteryCycleSessionKind.charge => Icons.bolt,
    BatteryCycleSessionKind.parked => Icons.local_parking,
  };

  /// Green marks the one kind that put energy back. Per `DESIGN.md` the
  /// semantic goes on the glyph and nowhere else on the row.
  Color _accent(AppThemeColors colors) {
    if (entry.deleted) return colors.inkSubtle;
    return entry.kind == BatteryCycleSessionKind.charge
        ? colors.energy.gain
        : colors.inkMuted;
  }

  String _kindLabel(AppLocalizations loc) {
    if (entry.deleted) return loc.v2CycleTimelineDeleted;
    return switch (entry.kind) {
      BatteryCycleSessionKind.trip => loc.v2CycleTimelineDrive,
      BatteryCycleSessionKind.charge => loc.v2CycleTimelineCharge,
      BatteryCycleSessionKind.parked => loc.v2CycleTimelineParked,
    };
  }

  /// Two readings per row, chosen so a column reads down the list: what the
  /// session moved, and what the pack did over it.
  ///
  /// A deleted session has neither, and a parked one never had a record of its
  /// own — for both, the duration is all the app can honestly state.
  List<String> _facts(AppLocalizations loc) {
    final duration = _duration();
    final trip = entry.trip;
    if (trip != null) {
      return [
        distanceLabelFor(
          distanceBetween(trip.startOdometerKm, trip.endOdometerKm),
          loc,
        ),
        socRangeLabel(trip.startSoc, trip.endSoc),
      ];
    }
    final charge = entry.charge;
    if (charge != null) {
      return [
        energyLabel(charge.estimatedEnergyKwh),
        socRangeLabel(charge.startSoc, charge.endSoc),
      ];
    }
    return [duration, '--'];
  }

  String _duration() {
    final span = entry.endUtcMillis - entry.startUtcMillis;
    if (span <= 0) return '--';
    return formatDuration(Duration(milliseconds: span));
  }
}

/// The one badge a timeline row can carry: how much of a split session this
/// battery took.
class _TimelineChip extends StatelessWidget {
  const _TimelineChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x2,
        vertical: AppSpacing.x1,
      ),
      decoration: BoxDecoration(
        color: colors.track,
        borderRadius: AppRadii.fullRadius,
      ),
      child: Text(
        label,
        style: AppText.caption.copyWith(color: colors.inkMuted),
        maxLines: 1,
      ),
    );
  }
}
