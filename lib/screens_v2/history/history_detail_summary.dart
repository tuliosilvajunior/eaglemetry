import 'package:flutter/material.dart';

import '../../core/efficiency_unit.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'history_detail_page.dart';

/// The docked card: which session is open, and enough of it to recognize.
class HistoryDetailSummaryCard extends StatelessWidget {
  const HistoryDetailSummaryCard({required this.page, super.key});

  final HistoryDetailPage page;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    // The efficiency fact reads EfficiencyUnitController directly rather than
    // taking the unit as a parameter, so listening here is what keeps this
    // card in step with every other reader of the same global choice.
    return ListenableBuilder(
      listenable: EfficiencyUnitController.instance,
      builder: (context, _) {
        final facts = page.facts(loc);
        return AppCard(
          title: page.title(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final fact in facts.take(4)) HistoryFactRow(fact: fact),
              const SizedBox(height: AppSpacing.x4),
              Text(
                loc.v2HistoryExpandHint,
                style: AppText.caption.copyWith(color: colors.inkSubtle),
              ),
            ],
          ),
        );
      },
    );
  }
}

class HistoryFactRow extends StatelessWidget {
  const HistoryFactRow({required this.fact, super.key});

  final HistoryFact fact;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              fact.label,
              style: AppText.label.copyWith(color: colors.inkSubtle),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.x3),
          Text(
            fact.value,
            style: AppText.bodyStrong.copyWith(color: colors.ink),
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}
