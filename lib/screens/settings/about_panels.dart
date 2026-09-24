part of '../settings_screen.dart';

class _AppUpdatePanel extends StatelessWidget {
  const _AppUpdatePanel({
    required this.checking,
    required this.installing,
    required this.status,
    required this.onCheck,
    required this.onInstall,
  });

  final bool checking;
  final bool installing;
  final AppUpdateStatus? status;
  final VoidCallback onCheck;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = _colors(context);
    final update = status;
    final languageCode = Localizations.localeOf(context).languageCode;
    final changelog = update == null
        ? const <AppChangelogEntry>[]
        : _pendingChangelog(update);
    final busy = checking || installing;
    final canInstall =
        !busy &&
        update != null &&
        update.checked &&
        update.compatible &&
        update.updateAvailable;
    final detail = checking && update == null
        ? loc.settingsAppUpdateChecking
        : update == null || !update.checked
        ? loc.settingsAppUpdateNotChecked
        : update.installScheduled
        ? loc.settingsAppUpdateScheduled
        : !update.compatible
        ? loc.settingsAppUpdateIncompatible(
            update.error ?? loc.settingsAppUpdateUnavailable,
          )
        : update.updateAvailable
        ? loc.settingsAppUpdateAvailable(
            update.availableVersionName ?? '--',
            update.availableVersionCode ?? 0,
          )
        : loc.settingsAppUpdateUpToDate;

    Widget progressIcon(IconData fallback, bool active) => active
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(fallback);

    return TechnicalPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.system_update_alt, size: 20, color: colors.secondary),
              const SizedBox(width: AutomotiveSpacing.x1),
              Expanded(
                child: Text(
                  loc.settingsAppUpdateTitle,
                  style: AutomotiveTextStyles.bodyMd.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AutomotiveSpacing.x0_5),
          Text(
            loc.settingsAppUpdateDescription,
            style: AutomotiveTextStyles.bodyMd.copyWith(
              color: colors.onSurfaceVariant,
              fontSize: 14,
            ),
          ),
          if (update != null) ...[
            const SizedBox(height: AutomotiveSpacing.x1),
            Text(
              loc.settingsAppUpdateInstalled(
                update.installedVersionName,
                update.installedVersionCode,
              ),
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: AutomotiveSpacing.x1),
          Text(
            detail,
            style: AutomotiveTextStyles.bodyMd.copyWith(
              color: update?.compatible == false
                  ? colors.error
                  : update?.updateAvailable == true
                  ? colors.secondary
                  : colors.onSurfaceVariant,
              fontWeight: update?.updateAvailable == true
                  ? FontWeight.w700
                  : FontWeight.w400,
            ),
          ),
          if (update?.updateAvailable == true && changelog.isNotEmpty) ...[
            const SizedBox(height: AutomotiveSpacing.x2),
            _AppReleaseNotes(entries: changelog, languageCode: languageCode),
          ],
          const SizedBox(height: AutomotiveSpacing.x2),
          Wrap(
            spacing: AutomotiveSpacing.x1,
            runSpacing: AutomotiveSpacing.x1,
            children: [
              SizedBox(
                height: AutomotiveDimensions.minTouchTarget,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : onCheck,
                  icon: progressIcon(Icons.refresh, checking),
                  label: Text(
                    checking
                        ? loc.settingsAppUpdateChecking
                        : loc.settingsAppUpdateCheck,
                  ),
                ),
              ),
              SizedBox(
                height: AutomotiveDimensions.minTouchTarget,
                child: FilledButton.icon(
                  onPressed: canInstall ? onInstall : null,
                  icon: progressIcon(Icons.download, installing),
                  label: Text(
                    installing
                        ? loc.settingsAppUpdateInstalling
                        : loc.settingsAppUpdateInstall,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

List<AppChangelogEntry> _pendingChangelog(AppUpdateStatus status) {
  final upperCode = status.availableVersionCode ?? 0;
  return status.changelog
      .where(
        (entry) =>
            entry.versionCode > status.installedVersionCode &&
            entry.versionCode <= upperCode,
      )
      .toList(growable: false)
    ..sort((left, right) => right.versionCode.compareTo(left.versionCode));
}

class _AppReleaseNotes extends StatelessWidget {
  const _AppReleaseNotes({required this.entries, required this.languageCode});

  final List<AppChangelogEntry> entries;
  final String languageCode;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = _colors(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AutomotiveSpacing.x2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            loc.settingsAppUpdateReleaseNotes,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: colors.secondary,
            ),
          ),
          const SizedBox(height: AutomotiveSpacing.x1),
          for (final entry in entries) ...[
            Text(
              '${entry.versionName} (${entry.versionCode})',
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: AutomotiveSpacing.x0_5),
            for (final note in entry.notesForLanguage(languageCode))
              Padding(
                padding: const EdgeInsets.only(bottom: AutomotiveSpacing.x0_5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('• ', style: TextStyle(color: colors.secondary)),
                    Expanded(
                      child: Text(
                        note,
                        style: AutomotiveTextStyles.bodyMd.copyWith(
                          color: colors.onSurfaceVariant,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _AppUpdateConfirmationDialog extends StatelessWidget {
  const _AppUpdateConfirmationDialog({required this.status});

  final AppUpdateStatus status;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final changelog = _pendingChangelog(status);
    return AlertDialog(
      title: Text(
        loc.settingsAppUpdateConfirmTitle(status.availableVersionName ?? '--'),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(loc.settingsAppUpdateConfirmDescription),
              if (changelog.isNotEmpty) ...[
                const SizedBox(height: AutomotiveSpacing.x2),
                _AppReleaseNotes(
                  entries: changelog,
                  languageCode: Localizations.localeOf(context).languageCode,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        SizedBox(
          height: AutomotiveDimensions.minTouchTarget,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(loc.settingsAppUpdateConfirmCancel),
          ),
        ),
        SizedBox(
          height: AutomotiveDimensions.minTouchTarget,
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.download),
            label: Text(loc.settingsAppUpdateConfirmInstall),
          ),
        ),
      ],
    );
  }
}

const _developerHandle = '@timoteohss';

class _AboutPanel extends StatelessWidget {
  const _AboutPanel();

  static final _random = math.Random();

  static const _confettiColors = <Color>[
    Color(0xFF3BB8FF),
    Color(0xFF30E3A2),
    Color(0xFFFFD447),
    Color(0xFFFF4B55),
  ];

  double _randomInRange(double min, double max) {
    return min + _random.nextDouble() * (max - min);
  }

  // Easter egg: launch several randomized bursts across the whole screen every
  // time the credit card is tapped.
  void _celebrate(BuildContext context) {
    HapticFeedback.mediumImpact();
    for (var burst = 0; burst < 6; burst++) {
      Confetti.launch(
        context,
        options: ConfettiOptions(
          angle: _randomInRange(55, 125),
          spread: _randomInRange(50, 70),
          particleCount: _randomInRange(35, 60).toInt(),
          startVelocity: _randomInRange(30, 50),
          x: _randomInRange(0.05, 0.95),
          y: _randomInRange(0.05, 0.95),
          colors: _confettiColors,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colorScheme = _colors(context);
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            DeveloperToolsGate.instance.registerEasterEggTap();
            _celebrate(context);
          },
          child: Padding(
            padding: AutomotiveSpacing.panelPadding,
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHigh,
                    borderRadius: AutomotiveRadii.fullRadius,
                  ),
                  child: Icon(
                    Icons.code,
                    color: colorScheme.secondary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: AutomotiveSpacing.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc.settingsAboutDeveloper(_developerHandle),
                        style: AutomotiveTextStyles.bodyMd.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AutomotiveSpacing.x0_5),
                      Text(
                        loc.settingsAboutTagline,
                        style: AutomotiveTextStyles.bodyMd.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppShellPanel extends StatelessWidget {
  const _AppShellPanel();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colorScheme = _colors(context);
    return AnimatedBuilder(
      animation: AppExperienceController.instance,
      builder: (context, _) {
        final selected = <bool>{AppExperienceController.instance.newUiEnabled};
        return TechnicalPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loc.settingsAppShellTitle,
                style: AutomotiveTextStyles.bodyLg.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AutomotiveSpacing.x1),
              Text(
                loc.settingsAppShellDescription,
                style: AutomotiveTextStyles.bodyMd.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AutomotiveSpacing.x2),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(loc.settingsAppShellNew),
                  ),
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.history),
                    label: Text(loc.settingsAppShellPrevious),
                  ),
                ],
                selected: selected,
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  HapticFeedback.selectionClick();
                  AppExperienceController.instance.setNewUiEnabled(
                    selection.first,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ClearDatabaseDialog extends StatelessWidget {
  const _ClearDatabaseDialog();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: _colors(context).surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: AutomotiveRadii.lgRadius),
      title: Text(
        loc.settingsWipeDialogTitle,
        style: AutomotiveTextStyles.headlineMd.copyWith(
          color: _colors(context).error,
        ),
      ),
      content: Text(
        loc.settingsWipeDialogContent,
        style: AutomotiveTextStyles.bodyMd.copyWith(
          color: _colors(context).onSurfaceVariant,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(loc.settingsCancel),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: Icon(Icons.delete_forever),
          label: Text(loc.settingsWipeAll),
          style: FilledButton.styleFrom(
            backgroundColor: _colors(context).errorContainer,
            foregroundColor: _colors(context).onErrorContainer,
            shape: RoundedRectangleBorder(
              borderRadius: AutomotiveRadii.baseRadius,
            ),
          ),
        ),
      ],
    );
  }
}
