part of '../settings_screen.dart';

class _SensorLabPanel extends StatelessWidget {
  const _SensorLabPanel();

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
                    loc.settingsSensorLab,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: _colors(context).onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AutomotiveSpacing.x0_5),
                  Text(
                    loc.settingsSensorLabDesc,
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
                onPressed: () {
                  HapticFeedback.selectionClick();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SensorLabScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.explore),
                label: Text(loc.settingsSensorLabOpen),
                style: FilledButton.styleFrom(
                  backgroundColor: _colors(context).secondary,
                  foregroundColor: _colors(context).onSecondary,
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

class _DangerPanel extends StatelessWidget {
  const _DangerPanel({
    required this.clearing,
    required this.status,
    required this.statusIsError,
    required this.onClear,
  });

  final bool clearing;
  final String? status;
  final bool statusIsError;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: _colors(context).surfaceContainer,
        border: Border.all(color: _colors(context).outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Column(
        children: [
          Padding(
            padding: AutomotiveSpacing.panelPadding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc.settingsWipe,
                        style: AutomotiveTextStyles.bodyMd.copyWith(
                          color: _colors(context).onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AutomotiveSpacing.x0_5),
                      Text(
                        loc.settingsWipeDesc,
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
                  child: OutlinedButton.icon(
                    onPressed: clearing ? null : onClear,
                    icon: clearing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.delete_forever),
                    label: Text(
                      clearing ? loc.settingsWiping : loc.settingsWipeHistory,
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _colors(context).error,
                      disabledForegroundColor: _colors(
                        context,
                      ).onSurfaceVariant,
                      side: BorderSide(color: _colors(context).error, width: 2),
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
          if (status != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AutomotiveSpacing.x3,
                vertical: AutomotiveSpacing.x2,
              ),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: _colors(context).outlineVariant),
                ),
              ),
              child: Text(
                status!,
                style: AutomotiveTextStyles.unitLabel.copyWith(
                  color: statusIsError
                      ? _colors(context).error
                      : _colors(context).secondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
