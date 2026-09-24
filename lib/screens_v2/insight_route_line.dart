import 'package:flutter/material.dart';

import '../core/insight.dart';
import '../core/insight_place.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

String insightRouteLine(InsightRouteMatch match, AppLocalizations loc) {
  final pair = '${match.from.displayName} → ${match.to.displayName}';
  if (match.tripCount <= 1) return pair;
  final trips = loc.insightRouteTrips(match.tripCount);
  if (match.variantCount <= 1) return '$pair · $trips';
  return '$pair · $trips · ${loc.insightRouteVariants(match.variantCount)}';
}

/// Start and end names, when the trip's ends resolve to named places.
///
/// Naming happens in "Consultar locais", so a trip detail never offers an
/// action here: an end with no place behind it is left out rather than shown
/// as an invitation.
class InsightTripPlaces extends StatelessWidget {
  const InsightTripPlaces({
    required this.subject,
    required this.places,
    required this.match,
    super.key,
  });

  final InsightTrip subject;
  final List<InsightPlace> places;
  final InsightRouteMatch? match;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    if (match != null) {
      return Text(
        insightRouteLine(match!, loc),
        style: AppText.body.copyWith(color: colors.ink),
      );
    }
    String? nameAt(InsightPoint? point) {
      if (point == null) return null;
      return placeContaining(point, places)?.displayName;
    }

    final startName = nameAt(subject.startPoint);
    final endName = nameAt(subject.endPoint);
    if (startName == null && endName == null) {
      return const SizedBox.shrink();
    }
    final children = <Widget>[
      if (startName != null)
        Text(startName, style: AppText.body.copyWith(color: colors.ink)),
    ];
    if (startName != null && endName != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
          child: Icon(Icons.arrow_forward, size: 18, color: colors.inkMuted),
        ),
      );
    }
    if (endName != null) {
      children.add(
        Text(endName, style: AppText.body.copyWith(color: colors.ink)),
      );
    }
    return Row(children: children);
  }
}
