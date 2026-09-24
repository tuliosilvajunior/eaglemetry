part of '../settings_screen.dart';

/// Roadcast daemon status with an explicit manual restart action.
///
/// O caminho automático nunca derruba um daemon saudável — fazer isso no meio de
/// uma viagem interromperia o registro dela. O efeito colateral é que um daemon de
/// uma versão anterior do app sobrevive a uma atualização e continua servindo o
/// snapshot antigo. Este botão é a saída para esse caso.
class _RoadcastPanel extends StatelessWidget {
  const _RoadcastPanel({
    required this.restarting,
    required this.checking,
    required this.updating,
    required this.status,
    required this.updateStatus,
    required this.onRestart,
    required this.onCheck,
    required this.onUpdate,
  });

  final bool restarting;
  final bool checking;
  final bool updating;
  final RoadcastStatus? status;
  final RoadcastUpdateStatus? updateStatus;
  final VoidCallback onRestart;
  final VoidCallback onCheck;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colorScheme = _colors(context);
    final current = status;
    final running = current?.running ?? false;
    final daemonDetail = current == null
        ? loc.settingsRoadcastUnavailable
        : running
        ? loc.settingsRoadcastRunning(
            current.frameCount,
            current.hz,
            current.signalCount,
          )
        : (current.error ?? loc.settingsRoadcastStopped);
    final update = updateStatus;
    final installedIdentity =
        update?.installedCommit ?? update?.installedSha256;
    final updateDetail = update == null || !update.checked
        ? loc.settingsRoadcastNotChecked
        : !update.compatible
        ? loc.settingsRoadcastIncompatible(
            update.error ?? loc.settingsRoadcastStopped,
          )
        : update.updateAvailable
        ? loc.settingsRoadcastUpdateAvailable(
            _shortRoadcastIdentity(update.availableCommit),
          )
        : loc.settingsRoadcastUpToDate;
    final busy = restarting || checking || updating;
    final canUpdate =
        !busy &&
        update != null &&
        update.checked &&
        update.compatible &&
        update.updateAvailable;

    Widget actionButton({
      required Widget icon,
      required String label,
      required VoidCallback? onPressed,
      bool filled = false,
    }) {
      final style = filled
          ? FilledButton.styleFrom(
              backgroundColor: colorScheme.secondary,
              foregroundColor: colorScheme.onSecondary,
              textStyle: AutomotiveTextStyles.labelCaps,
              padding: const EdgeInsets.symmetric(
                horizontal: AutomotiveSpacing.x3,
              ),
            )
          : OutlinedButton.styleFrom(
              foregroundColor: colorScheme.onSurface,
              side: BorderSide(color: colorScheme.outlineVariant),
              textStyle: AutomotiveTextStyles.labelCaps,
              padding: const EdgeInsets.symmetric(
                horizontal: AutomotiveSpacing.x3,
              ),
            );
      final child = filled
          ? FilledButton.icon(
              onPressed: onPressed,
              icon: icon,
              label: Text(label),
              style: style,
            )
          : OutlinedButton.icon(
              onPressed: onPressed,
              icon: icon,
              label: Text(label),
              style: style,
            );
      return SizedBox(
        height: AutomotiveDimensions.minTouchTarget,
        child: child,
      );
    }

    Widget progressIcon(IconData fallback, bool active) => active
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(fallback);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Padding(
        padding: AutomotiveSpacing.panelPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  running ? Icons.check_circle : Icons.error_outline,
                  size: 18,
                  color: running ? colorScheme.primary : colorScheme.error,
                ),
                const SizedBox(width: AutomotiveSpacing.x1),
                Text(
                  loc.settingsRoadcastTitle,
                  style: AutomotiveTextStyles.bodyMd.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AutomotiveSpacing.x0_5),
            Text(
              daemonDetail,
              style: AutomotiveTextStyles.bodyMd.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
            if (installedIdentity != null) ...[
              const SizedBox(height: AutomotiveSpacing.x0_5),
              Text(
                loc.settingsRoadcastInstalled(
                  _shortRoadcastIdentity(installedIdentity),
                ),
                style: AutomotiveTextStyles.unitLabel.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AutomotiveSpacing.x1),
            Text(
              updateDetail,
              style: AutomotiveTextStyles.bodyMd.copyWith(
                color: update?.updateAvailable == true
                    ? colorScheme.secondary
                    : update?.compatible == false
                    ? colorScheme.error
                    : colorScheme.onSurfaceVariant,
                fontSize: 14,
                fontWeight: update?.updateAvailable == true
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
            ),
            const SizedBox(height: AutomotiveSpacing.x2),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: AutomotiveSpacing.x1,
                runSpacing: AutomotiveSpacing.x1,
                children: [
                  actionButton(
                    icon: progressIcon(Icons.refresh, checking),
                    label: checking
                        ? loc.settingsRoadcastChecking
                        : loc.settingsRoadcastCheck,
                    onPressed: busy ? null : onCheck,
                  ),
                  actionButton(
                    icon: progressIcon(Icons.system_update_alt, updating),
                    label: updating
                        ? loc.settingsRoadcastUpdating
                        : loc.settingsRoadcastUpdate,
                    onPressed: canUpdate ? onUpdate : null,
                    filled: true,
                  ),
                  actionButton(
                    icon: progressIcon(Icons.restart_alt, restarting),
                    label: restarting
                        ? loc.settingsRoadcastRestarting
                        : loc.settingsRoadcastRestart,
                    onPressed: busy ? null : onRestart,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
