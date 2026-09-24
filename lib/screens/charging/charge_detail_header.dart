import 'package:flutter/material.dart';

import '../../design_system/design_system.dart';
import '../../l10n/app_localizations.dart';

/// Barra de topo das telas de detalhe de carga, ao vivo e histórica.
///
/// A tela grande já diz o que é pelo conteúdo; esta faixa existe só para o que o
/// conteúdo não pode dar — voltar, identificar a sessão e recarregar. Os chips são
/// da tela, porque o que qualifica uma sessão ao vivo (barramento, pulso) não é o
/// que qualifica uma encerrada (frames, motivo de fim).
class ChargeDetailHeader extends StatelessWidget {
  const ChargeDetailHeader({
    required this.title,
    required this.shortId,
    required this.loading,
    required this.onRefresh,
    this.chips = const <Widget>[],
    super.key,
  });

  final String title;
  final String shortId;
  final bool loading;
  final VoidCallback onRefresh;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      height: AutomotiveDimensions.minTouchTarget,
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.marginScreen,
      ),
      decoration: BoxDecoration(
        color: AutomotiveColors.surface,
        border: Border(
          bottom: BorderSide(color: AutomotiveColors.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: AutomotiveDimensions.minTouchTarget,
            height: AutomotiveDimensions.minTouchTarget,
            child: IconButton(
              tooltip: loc.detailBack,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
              color: AutomotiveColors.onSurface,
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x1),
          Text(
            title,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: AutomotiveColors.onSurface,
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          Flexible(
            child: Text(
              shortId,
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
              ),
            ),
          ),
          const Spacer(),
          // Os chips podem estourar a largura num painel estreito; rolar é
          // preferível a encolher o texto até virar ilegível.
          Flexible(
            flex: 4,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(mainAxisSize: MainAxisSize.min, children: chips),
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          SizedBox(
            width: AutomotiveDimensions.minTouchTarget,
            height: AutomotiveDimensions.minTouchTarget,
            child: IconButton(
              tooltip: loc.detailRefresh,
              onPressed: loading ? null : onRefresh,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              color: AutomotiveColors.secondary,
            ),
          ),
        ],
      ),
    );
  }
}
