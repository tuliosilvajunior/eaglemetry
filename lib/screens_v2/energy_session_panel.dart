import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// The `Session details` card: what the shown stretch of driving spent, split
/// into the buckets the telemetry actually measures.
///
/// The ring is the energy drawn; regeneration is the inner arc, because it is
/// measured *against* that rather than being a slice of it.
///
/// Traction is `VCU_DrvPwrAct`, pinned to the pack side at slope 1 by a closure test,
/// so the remainder `pack − drive` is genuinely the auxiliary load and not a
/// drivetrain loss. Climate is carved out of that remainder only when the car
/// reports climate power with a verified scale. What is left is the system
/// share, and it is left deliberately unnamed: it holds the steering assist,
/// the pumps, the lamps, the electronics, and — while cooling — the part of the
/// climate package the car's own counter leaves out.
///
/// When the split is not measured the ring keeps two slices, and the whole
/// remainder stays in the system share rather than being apportioned.
class EnergySessionPanel extends StatelessWidget {
  const EnergySessionPanel({
    required this.buckets,
    required this.loading,
    required this.failed,
    this.showTitle = true,
    super.key,
  });

  /// Whether the card names itself.
  ///
  /// The header is the one part of this panel that costs the ring height
  /// without telling the reader anything the ring does not. A screen that
  /// already says whose drive this is, and how long it took, passes false and
  /// the ring takes that band — which on the session detail is the difference
  /// between a 128 px ring and a 212 px one. The info button does not go with
  /// it; it moves down beside the legend it explains.
  ///
  /// The caller decides, not the panel. Only the caller knows what else is on
  /// the screen, and a panel that dropped its own title whenever it felt
  /// cramped would drop it on the one screen where nothing else names it.
  final bool showTitle;

  /// The same series the chart draws, before reduction.
  final List<EnergyBucket> buckets;

  final bool loading;

  /// A read that failed leaves this panel unknown, not empty. Reporting "no
  /// driving recorded" for a broken pool would state as fact something the app
  /// never managed to look up.
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    // Only the duration is read here. The ring reads the composition itself,
    // because it is the one that draws it.
    final seconds = readEnergyComposition(buckets).seconds;

    return AppCard(
      title: showTitle ? loc.sessionDetailsTitle : null,
      subtitle: showTitle && seconds > 0 ? _duration(loc, seconds) : null,
      // Without a title there is no header row to hold it, and one built only
      // for the button would cost the ring the same band the title did — the
      // button is a full touch target, so a header of just the button is no
      // shorter than a header with the words in it.
      trailing: showTitle ? const _SessionLegendInfoButton() : null,
      child: EnergySessionRing(
        buckets: buckets,
        loading: loading,
        failed: failed,
        // The card's header already carries it when there is a header.
        showInfoButton: !showTitle,
      ),
    );
  }

  /// Time the integral actually covers, which is not the wall span: a stretch
  /// the car reported nothing for is not time this reading knows about.
  String _duration(AppLocalizations loc, double seconds) {
    final total = Duration(seconds: seconds.round());
    final hours = total.inHours;
    final minutes = total.inMinutes.remainder(60);
    return hours > 0 ? '${hours}h ${minutes}min' : '${minutes}min';
  }
}

/// The ring itself, without a card around it.
///
/// Separate from [EnergySessionPanel] because two surfaces want the reading
/// without wanting a card of their own: the CarPlay and Android Auto context
/// columns already have one, and it carries their reattach action.
class EnergySessionRing extends StatelessWidget {
  const EnergySessionRing({
    required this.buckets,
    required this.loading,
    required this.failed,
    this.showInfoButton = false,
    super.key,
  });

  /// The same series the chart draws, before reduction.
  final List<EnergyBucket> buckets;

  final bool loading;

  /// A read that failed leaves this ring unknown, not empty.
  final bool failed;

  /// Whether the ring carries the legend's info button itself.
  ///
  /// False when the surface around it already shows one — a second button for
  /// the same explanation is one the reader has to choose between.
  final bool showInfoButton;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    final energy = readEnergyComposition(buckets);
    final traction = energy.traction;
    final climate = energy.climate;
    final system = energy.system;
    final regenerated = energy.regenerated;
    final drawn = energy.drawn;

    return drawn <= 0
        ? Center(
            child: Text(
              failed
                  ? loc.energyChartFailed
                  : loading
                  ? loc.energyChartLoading
                  : loc.energyChartEmpty,
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              // A card too short for both loses the footer, and each reading
              // moves onto its own arc instead. The ring is the panel; a
              // legend under a ring squeezed to nothing is the wrong half to
              // keep, and it is the half whose information the arcs can carry
              // themselves.
              final compact =
                  constraints.hasBoundedHeight &&
                  constraints.maxHeight < _footerFloor;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // A card with neither a header nor a footer has nowhere
                  // else to put the button, and the reader would lose the
                  // only surface that says what the glyphs mean.
                  if (showInfoButton && compact)
                    const Align(
                      alignment: Alignment.centerRight,
                      child: _SessionLegendInfoButton(),
                    ),
                  Expanded(
                    child: SegmentedDonut(
                      markerExtent: compact ? _readoutMarker : null,
                      segments: [
                        DonutSegment(
                          value: traction,
                          color: AppThemeColors.of(context).energy.draw,
                          marker: _marker(
                            compact: compact,
                            icon: Icons.grid_view,
                            color: AppThemeColors.of(context).energy.draw,
                            value: _kwh(loc, traction),
                          ),
                        ),
                        if (climate > 0)
                          DonutSegment(
                            value: climate,
                            color: AppThemeColors.of(context).energy.drawSoft,
                            marker: _marker(
                              compact: compact,
                              icon: Icons.air,
                              color: AppThemeColors.of(context).energy.drawSoft,
                              value: _kwh(loc, climate),
                            ),
                          ),
                        // A residual that came out negative is not a share of
                        // the ring; it is a reading the split cannot use.
                        if (system > 0)
                          DonutSegment(
                            value: system,
                            color: AppThemeColors.of(context).energy.drawSubtle,
                            marker: _marker(
                              compact: compact,
                              icon: Icons.electrical_services,
                              color: AppThemeColors.of(
                                context,
                              ).energy.drawSubtle,
                              value: _kwh(loc, system),
                            ),
                          ),
                      ],
                      innerArc: regenerated > 0
                          ? DonutInnerArc(
                              value: regenerated,
                              color: AppThemeColors.of(context).energy.gain,
                            )
                          : null,
                      value: (drawn / 1000).toStringAsFixed(1),
                      unit: loc.unitKwh,
                      delta: regenerated > 0
                          ? '+${_kwh(loc, regenerated)}'
                          : null,
                      semanticsLabel: loc.energyChartSemantics,
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(height: AppSpacing.x4),
                    _LegendRow(
                      // The legend is two rows of glyphs and the button is
                      // one touch target, so the button rides beside it for
                      // free: the row is already as tall as the button is.
                      info: showInfoButton
                          ? const _SessionLegendInfoButton()
                          : null,
                      child: IconValueGrid(
                        entries: [
                          IconValueEntry(
                            icon: Icons.grid_view,
                            value: _kwh(loc, traction),
                            color: AppThemeColors.of(context).energy.draw,
                            semanticLabel: loc.energyTraction,
                          ),
                          if (climate > 0)
                            IconValueEntry(
                              icon: Icons.air,
                              value: _kwh(loc, climate),
                              color: AppThemeColors.of(context).energy.drawSoft,
                              semanticLabel: loc.energyClimate,
                            ),
                          if (system > 0)
                            IconValueEntry(
                              icon: Icons.electrical_services,
                              value: _kwh(loc, system),
                              color: AppThemeColors.of(
                                context,
                              ).energy.drawSubtle,
                              semanticLabel: loc.energyAuxiliary,
                            ),
                          if (regenerated > 0)
                            IconValueEntry(
                              icon: Icons.trending_up,
                              value: _kwh(loc, regenerated),
                              color: AppThemeColors.of(context).energy.gain,
                              semanticLabel: loc.energyRegeneration,
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          );
  }

  /// Height under which the footer legend gives way to arc readouts.
  ///
  /// Measured against the card's content box, not the screen: the same panel
  /// is the trailing column of a wide row on one screen and a short cell above
  /// a map on another.
  static const _footerFloor = 360.0;

  /// Box each arc readout is laid out in. Wide enough for `26.6 kWh` under its
  /// glyph, and the ring insets by the larger side — see
  /// `SegmentedDonut.markerExtent`.
  static const _readoutMarker = Size(72, 44);

  String _kwh(AppLocalizations loc, double wh) =>
      '${(wh / 1000).toStringAsFixed(1)} ${loc.unitKwh}';

  /// The glyph on an arc — with its reading under it when the footer that would
  /// otherwise carry it has been dropped.
  Widget _marker({
    required bool compact,
    required IconData icon,
    required Color color,
    required String value,
  }) {
    if (!compact) return Icon(icon, size: AppSizes.iconMd);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Semantic color goes on the glyph, never on the text — `DESIGN.md`.
        Icon(icon, size: AppSizes.iconSm, color: color),
        Text(value, style: AppText.legendValue, maxLines: 1),
      ],
    );
  }
}

/// The footer legend, with the button that explains it when the header the
/// button usually rides is not there.
///
/// The button costs the ring nothing here. The legend is two rows of glyphs and
/// therefore already as tall as one touch target, so the row's height is the
/// same with the button as without it.
class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.child, this.info});

  final Widget child;
  final Widget? info;

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    if (info == null) return child;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: child),
        const SizedBox(width: AppSpacing.x2),
        info,
      ],
    );
  }
}

/// Explains the ring's legend, keyed by the icons the panel actually draws.
///
/// All four entries are always present, including a share the car did not
/// report and one whose reading came out unusable and was left off the ring.
/// The panel is where the reader learns what the glyphs mean, and a legend that
/// appears and disappears with the data cannot teach that.
class _SessionLegendInfoButton extends StatelessWidget {
  const _SessionLegendInfoButton();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return AnchoredTooltipTrigger(
      // The panel is the trailing column, so there is only ever room inboard.
      side: AnchoredTooltipSide.left,
      caretAlignment: 0.08,
      anchorInsets: const EdgeInsets.all(AppSpacing.x4),
      barrierLabel: loc.sessionDetailsInfoClose,
      tooltipBuilder: (context) => InformationTooltipPanel(
        title: loc.sessionDetailsInfoTitle,
        children: [
          InformationCard(
            icon: Icons.grid_view,
            iconColor: AppThemeColors.of(context).energy.draw,
            value: loc.energyTraction,
            description: loc.sessionDetailsInfoTraction,
          ),
          InformationCard(
            icon: Icons.air,
            iconColor: AppThemeColors.of(context).energy.drawSoft,
            value: loc.energyClimate,
            description: loc.sessionDetailsInfoClimate,
          ),
          InformationCard(
            icon: Icons.electrical_services,
            iconColor: AppThemeColors.of(context).energy.drawSubtle,
            value: loc.energyAuxiliary,
            description: loc.sessionDetailsInfoAuxiliary,
          ),
          InformationCard(
            icon: Icons.trending_up,
            iconColor: AppThemeColors.of(context).energy.gain,
            value: loc.energyRegeneration,
            description: loc.sessionDetailsInfoRegeneration,
          ),
        ],
      ),
      builder: (context, isOpen, open) => InfoIconButton(
        selected: isOpen,
        onPressed: open,
        tooltip: loc.sessionDetailsAbout,
      ),
    );
  }
}
