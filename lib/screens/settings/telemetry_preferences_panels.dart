part of '../settings_screen.dart';

class _RetentionPanel extends StatelessWidget {
  const _RetentionPanel({required this.running, required this.onRun});

  final bool running;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: _colors(context).surfaceContainer,
        border: Border.all(color: _colors(context).outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Padding(
        padding: AutomotiveSpacing.panelPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loc.settingsRetention,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AutomotiveSpacing.x0_5),
                  Text(
                    loc.settingsRetentionDesc,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurfaceVariant,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x3),
            SizedBox(
              height: AutomotiveDimensions.minTouchTarget,
              child: FilledButton.icon(
                onPressed: running ? null : onRun,
                icon: running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.auto_delete),
                label: Text(
                  running
                      ? loc.settingsRetentionRunning
                      : loc.settingsRetentionRun,
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _colors(context).secondary,
                  foregroundColor: _colors(context).onSecondary,
                  disabledBackgroundColor: _colors(
                    context,
                  ).surfaceContainerHighest,
                  disabledForegroundColor: _colors(context).onSurfaceVariant,
                  shape: RoundedRectangleBorder(
                    borderRadius: AutomotiveRadii.baseRadius,
                  ),
                  textStyle: AutomotiveTextStyles.labelCaps,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AutomotiveSpacing.x3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AutoStartPanel extends StatelessWidget {
  const _AutoStartPanel({
    required this.loading,
    required this.enabled,
    required this.onChanged,
  });

  final bool loading;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: _colors(context).surfaceContainer,
        border: Border.all(color: _colors(context).outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Padding(
        padding: AutomotiveSpacing.panelPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loc.settingsAutoStart,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AutomotiveSpacing.x0_5),
                  Text(
                    loc.settingsAutoStartDesc,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurfaceVariant,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x3),
            Switch(value: enabled, onChanged: loading ? null : onChanged),
          ],
        ),
      ),
    );
  }
}

class _GpsPanel extends StatelessWidget {
  const _GpsPanel({
    required this.loading,
    required this.enabled,
    required this.onChanged,
  });

  final bool loading;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: _colors(context).surfaceContainer,
        border: Border.all(color: _colors(context).outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Padding(
        padding: AutomotiveSpacing.panelPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loc.settingsGps,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AutomotiveSpacing.x0_5),
                  Text(
                    loc.settingsGpsDesc,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurfaceVariant,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x3),
            Switch(value: enabled, onChanged: loading ? null : onChanged),
          ],
        ),
      ),
    );
  }
}

class _ReplaceOemChargingPanel extends StatelessWidget {
  const _ReplaceOemChargingPanel({
    required this.loading,
    required this.enabled,
    required this.onChanged,
  });

  final bool loading;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: _colors(context).surfaceContainer,
        border: Border.all(color: _colors(context).outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Padding(
        padding: AutomotiveSpacing.panelPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loc.settingsReplaceOemChargingTitle,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AutomotiveSpacing.x0_5),
                  Text(
                    loc.settingsReplaceOemChargingDesc,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurfaceVariant,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x3),
            Switch(value: enabled, onChanged: loading ? null : onChanged),
          ],
        ),
      ),
    );
  }
}

class _EventFilePanel extends StatelessWidget {
  const _EventFilePanel({
    required this.loading,
    required this.enabled,
    required this.onChanged,
  });

  final bool loading;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: _colors(context).surfaceContainer,
        border: Border.all(color: _colors(context).outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Padding(
        padding: AutomotiveSpacing.panelPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loc.settingsEventFile,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AutomotiveSpacing.x0_5),
                  Text(
                    loc.settingsEventFileDesc,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurfaceVariant,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x3),
            Switch(value: enabled, onChanged: loading ? null : onChanged),
          ],
        ),
      ),
    );
  }
}

class _ChargeCostSettingsPanel extends StatelessWidget {
  const _ChargeCostSettingsPanel({
    required this.loading,
    required this.currency,
    required this.currentValue,
    required this.draftValue,
    required this.onChanged,
    required this.onClear,
    required this.onSave,
  });

  final bool loading;
  final String currency;
  final double? currentValue;
  final double draftValue;
  final ValueChanged<double> onChanged;
  final VoidCallback onClear;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final currencySymbol = chargeCurrencySymbolForLocale(
      loc.localeName,
      fallbackCurrency: currency,
    );
    final savedValue = currentValue == null
        ? loc.settingsChargeCostNotSaved
        : loc.settingsChargeCostSaved(
            '$currencySymbol ${currentValue!.toStringAsFixed(2)} / kWh',
          );
    return Container(
      decoration: BoxDecoration(
        color: _colors(context).surfaceContainer,
        border: Border.all(color: _colors(context).outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Padding(
        padding: AutomotiveSpacing.panelPadding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 860;
            final controls = _ChargeCostCryptexControls(
              loading: loading,
              currency: currencySymbol,
              value: draftValue,
              onChanged: onChanged,
              onClear: onClear,
              onSave: onSave,
            );
            final description = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loc.settingsChargeCostTitle,
                  style: AutomotiveTextStyles.bodyMd.copyWith(
                    color: _colors(context).onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AutomotiveSpacing.x0_5),
                Text(
                  loc.settingsChargeCostDesc,
                  style: AutomotiveTextStyles.bodyMd.copyWith(
                    color: _colors(context).onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: AutomotiveSpacing.x1),
                Text(
                  savedValue,
                  style: AutomotiveTextStyles.unitLabel.copyWith(
                    color: currentValue == null
                        ? _colors(context).onSurfaceVariant
                        : _colors(context).secondary,
                    fontSize: 12,
                  ),
                ),
              ],
            );

            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  description,
                  const SizedBox(height: AutomotiveSpacing.x2),
                  controls,
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: description),
                const SizedBox(width: AutomotiveSpacing.x3),
                SizedBox(width: 520, child: controls),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ChargeCostCryptexControls extends StatelessWidget {
  const _ChargeCostCryptexControls({
    required this.loading,
    required this.currency,
    required this.value,
    required this.onChanged,
    required this.onClear,
    required this.onSave,
  });

  final bool loading;
  final String currency;
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onClear;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ChargeCostCryptex(
            value: value,
            currency: currency,
            suffix: '/ kWh',
            enabled: !loading,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(height: AutomotiveSpacing.x2),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: AutomotiveDimensions.minTouchTarget,
                child: OutlinedButton.icon(
                  onPressed: loading ? null : onClear,
                  icon: const Icon(Icons.clear),
                  label: Text(loc.actionClear),
                ),
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x2),
            Expanded(
              child: SizedBox(
                height: AutomotiveDimensions.minTouchTarget,
                child: FilledButton.icon(
                  onPressed: loading ? null : onSave,
                  icon: const Icon(Icons.save),
                  label: Text(loc.actionSave),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
