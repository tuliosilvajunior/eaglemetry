import 'package:flutter/material.dart';

import '../core/insight.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// The slice-1 sentence: one closed trip against the last 30 days.
///
/// The widget prints what [compareTripToOwnAverage] decided. It does not
/// compute a second number.
class OwnAverageInsight extends StatelessWidget {
  const OwnAverageInsight({required this.read, super.key});

  final InsightRead read;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return Text(
      insightPhraseText(insightPhrase(read), loc),
      style: AppText.body.copyWith(color: colors.inkMuted),
    );
  }
}

/// Translates an [InsightPhrase] decided by `telemetry_core` to localized text.
String insightPhraseText(
  InsightPhrase phrase,
  AppLocalizations loc,
) => switch (phrase) {
  InsightPhraseSubjectUnusable() => loc.insightSubjectUnusable,
  InsightPhraseNotEnoughData(:final count) => loc.insightNotEnoughData(count),
  InsightPhraseNotDistinguishable(:final count) =>
    loc.insightNotDistinguishable(count),
  InsightPhraseUsedLess(:final difference, :final count) =>
    loc.insightTripUsedLess(difference, count),
  InsightPhraseUsedMore(:final difference, :final count) =>
    loc.insightTripUsedMore(difference, count),
  InsightPhraseVariantNotEnough(:final count) => loc.insightVariantNotEnough(
    count,
  ),
  InsightPhraseVariantNotDistinguishable(:final place, :final count) =>
    loc.insightVariantNotDistinguishable(place, count),
  InsightPhraseVariantUsedLess(:final difference, :final place, :final count) =>
    loc.insightVariantUsedLess(difference, place, count),
  InsightPhraseVariantUsedMore(:final difference, :final place, :final count) =>
    loc.insightVariantUsedMore(difference, place, count),
};
