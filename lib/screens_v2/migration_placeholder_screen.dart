import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

class MigrationPlaceholderScreen extends StatelessWidget {
  const MigrationPlaceholderScreen({
    required this.title,
    required this.icon,
    super.key,
  });

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return SizedBox.expand(
      child: ThreeColumnLayout(
        leading: AppCard(
          title: loc.v2Overview,
          child: _Placeholder(icon: icon, label: loc.v2MigrationPlaceholder),
        ),
        primary: AppCard(
          title: title,
          child: _Placeholder(icon: icon, label: loc.v2MigrationPlaceholder),
        ),
        trailing: AppCard(
          title: loc.v2Context,
          child: _Placeholder(icon: icon, label: loc.v2MigrationPlaceholder),
        ),
      ),
    );
  }
}

/// The "not migrated yet" block, for a screen that owns some real content and
/// still has panels waiting on a migration.
class MigrationPlaceholder extends StatelessWidget {
  const MigrationPlaceholder({
    required this.icon,
    required this.label,
    super.key,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => _Placeholder(icon: icon, label: label);
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppSizes.iconLg, color: colors.inkSubtle),
          const SizedBox(height: AppSpacing.x3),
          Text(label, style: AppText.label, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
