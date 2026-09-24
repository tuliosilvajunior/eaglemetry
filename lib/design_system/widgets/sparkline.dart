import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_typography.dart';

/// Linha de tendência sem eixos, para valores ao vivo.
///
/// Usada onde não cabe um gráfico com eixos mas ainda importa ver a **forma** do
/// sinal: gauge da tela Trace e leituras da tela live de trip. Escala em Y pelo
/// próprio mínimo/máximo da janela, porque a pergunta é "está subindo ou descendo",
/// não "quanto vale" — o valor está escrito ao lado.
class Sparkline extends StatelessWidget {
  const Sparkline({
    required this.values,
    this.color,
    this.strokeWidth = 1.5,
    this.fill = true,
    this.emptyMessage,
    super.key,
  });

  final List<double> values;
  final Color? color;
  final double strokeWidth;

  /// Área sob a linha em cor esmaecida. Ajuda a distinguir duas sparklines
  /// empilhadas quando a linha é fina.
  final bool fill;

  /// Texto para quando ainda não há dois pontos. Omitir deixa o espaço vazio, que é
  /// o certo quando a sparkline é acessório de um número já visível.
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    final line = color ?? AutomotiveColors.secondary;
    final message = emptyMessage;
    return CustomPaint(
      painter: _SparklinePainter(
        values: values,
        color: line,
        fill: fill,
        strokeWidth: strokeWidth,
      ),
      child: values.length < 2 && message != null
          ? Center(
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: AutomotiveTextStyles.bodyMd.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                ),
              ),
            )
          : const SizedBox.expand(),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({
    required this.values,
    required this.color,
    required this.fill,
    required this.strokeWidth,
  });

  final List<double> values;
  final Color color;
  final bool fill;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var min = values.first;
    var max = values.first;
    for (final value in values) {
      min = math.min(min, value);
      max = math.max(max, value);
    }
    // Sinal constante desenha uma reta no meio em vez de dividir por zero.
    final span = (max - min).abs() < 1e-9 ? 1.0 : max - min;

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height - ((values[i] - min) / span) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    if (fill) {
      final area = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.12));
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke,
    );
  }

  // Sempre repinta. O chamador costuma passar a **mesma** lista, mutada no lugar
  // (a FIFO de histórico do sinal), e nesse caso qualquer comparação contra
  // `oldDelegate.values` compara a lista com ela mesma e diz que nada mudou — foi
  // assim que a sparkline do gauge congelava ao encher a janela. Repintar uma
  // polilinha de ~120 pontos é barato o bastante para não valer o risco.
  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) => true;
}
