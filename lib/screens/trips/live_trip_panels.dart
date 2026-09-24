import 'package:flutter/material.dart';

import '../../core/eco_coach.dart';
import '../../design_system/design_system.dart';

/// Peças de apresentação da tela live de trip.
///
/// Ficam separadas do estado porque a tela junta três fontes (CAN por FFI, property
/// pelo stream, agregados do Room) e o arquivo do `State` já carrega essa costura.
/// Aqui embaixo nada sabe de onde o número veio — só como ele aparece, incluindo o
/// selo que diz qual é a fonte, que é metade da informação numa tela dessas.

/// O quanto se pode confiar num número ao vivo.
///
/// Existe porque este carro entrega valores calibrados, derivados e crus com a
/// mesma cara de medição.
enum LiveTrust {
  /// Escala confirmada: número é medição.
  calibrated,

  /// Derivado de duas medições confiáveis (V×I).
  derived,

  /// Contagem crua do barramento, sem escala física.
  raw,
}

class LiveEcoCoachReason {
  const LiveEcoCoachReason({required this.window, required this.label});

  final EcoCoachReasonWindow window;
  final String label;
}

/// Gauge compacto do Eco Coach: nota, motivos recentes e evidências observáveis.
class LiveEcoCoachPanel extends StatelessWidget {
  const LiveEcoCoachPanel({
    required this.snapshot,
    required this.title,
    required this.reasons,
    required this.timestamp,
    required this.observingLabel,
    required this.accelerationLabel,
    required this.jerkLabel,
    required this.cyclesLabel,
    required this.betaLabel,
    super.key,
  });

  final EcoCoachSnapshot snapshot;
  final String title;
  final List<LiveEcoCoachReason> reasons;
  final Duration timestamp;
  final String observingLabel;
  final String accelerationLabel;
  final String jerkLabel;
  final String cyclesLabel;
  final String betaLabel;

  @override
  Widget build(BuildContext context) {
    final score = snapshot.score;
    final color = score == null
        ? AutomotiveColors.outline
        : score >= 80
        ? AutomotiveColors.secondary
        : score >= 55
        ? AutomotiveColors.warning
        : AutomotiveColors.error;
    final activeReasons =
        reasons
            .where((reason) => reason.window.opacityAt(timestamp) > 0)
            .toList(growable: false)
          ..sort(_compareReasons);
    return Column(
      key: const ValueKey('live_trip_eco_coach'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: AutomotiveTextStyles.labelCaps.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                ),
              ),
            ),
            StatusBadge(label: betaLabel, color: AutomotiveColors.outline),
          ],
        ),
        const SizedBox(height: AutomotiveSpacing.x0_5),
        Text(
          score?.round().toString() ?? '--',
          style: AutomotiveTextStyles.metricDisplay.copyWith(
            color: color,
            fontSize: 48,
          ),
        ),
        const SizedBox(height: AutomotiveSpacing.x1),
        if (activeReasons.isEmpty)
          Text(
            observingLabel,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AutomotiveTextStyles.bodyMd.copyWith(color: color),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final reason in activeReasons)
                _EcoReasonRow(reason: reason, timestamp: timestamp),
            ],
          ),
        const SizedBox(height: AutomotiveSpacing.x1),
        SocBar(
          fraction: score == null ? 0 : score / 100,
          color: color,
          height: 8,
        ),
        const SizedBox(height: AutomotiveSpacing.x1),
        Wrap(
          spacing: AutomotiveSpacing.x2,
          runSpacing: AutomotiveSpacing.x0_5,
          children: [
            _EcoEvidence(
              label: accelerationLabel,
              value: _signed(snapshot.accelerationMps2, 'm/s²'),
            ),
            _EcoEvidence(
              label: jerkLabel,
              value: _signed(snapshot.jerkMps3, 'm/s³'),
            ),
            _EcoEvidence(
              label: cyclesLabel,
              value: '${snapshot.accelerateBrakeCycles}',
            ),
          ],
        ),
      ],
    );
  }

  static String _signed(double? value, String unit) => value == null
      ? '--'
      : '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)} $unit';

  static int _compareReasons(
    LiveEcoCoachReason left,
    LiveEcoCoachReason right,
  ) {
    final severity = left.window.reason.severity.index.compareTo(
      right.window.reason.severity.index,
    );
    if (severity != 0) return severity;
    return left.label.toLowerCase().compareTo(right.label.toLowerCase());
  }
}

class _EcoReasonRow extends StatelessWidget {
  const _EcoReasonRow({required this.reason, required this.timestamp});

  final LiveEcoCoachReason reason;
  final Duration timestamp;

  @override
  Widget build(BuildContext context) {
    final color = switch (reason.window.reason.severity) {
      EcoCoachReasonSeverity.positive => AutomotiveColors.secondary,
      EcoCoachReasonSeverity.warning => AutomotiveColors.warning,
      EcoCoachReasonSeverity.critical => AutomotiveColors.error,
    };
    return AnimatedOpacity(
      key: ValueKey('eco_reason_${reason.window.reason.name}'),
      opacity: reason.window.opacityAt(timestamp),
      duration: const Duration(milliseconds: 120),
      curve: Curves.linear,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AutomotiveSpacing.x0_5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: color,
                borderRadius: AutomotiveRadii.fullRadius,
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x1),
            Expanded(
              child: Text(
                reason.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AutomotiveTextStyles.bodyMd.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EcoEvidence extends StatelessWidget {
  const _EcoEvidence({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text(
    '$label $value',
    style: AutomotiveTextStyles.unitLabel.copyWith(
      color: AutomotiveColors.onSurfaceVariant,
      fontSize: 10,
    ),
  );
}

/// Selo de fonte/confiança ao lado de um valor ao vivo.
class LiveSourceBadge extends StatelessWidget {
  const LiveSourceBadge({
    required this.label,
    this.trust,
    this.stale = false,
    super.key,
  });

  final String label;
  final LiveTrust? trust;

  /// Fonte parou de publicar: o valor na tela é o último conhecido, não o atual.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    return StatusBadge(label: label, color: _color(), fontSize: 9);
  }

  Color _color() {
    if (stale) return AutomotiveColors.error;
    switch (trust) {
      case LiveTrust.calibrated:
        return AutomotiveColors.secondary;
      case LiveTrust.derived:
        return AutomotiveColors.tertiary;
      case LiveTrust.raw:
      case null:
        return AutomotiveColors.outline;
    }
  }
}

/// Leitura grande: o número que se lê de relance dirigindo.
class LiveHeroReadout extends StatelessWidget {
  const LiveHeroReadout({
    required this.label,
    required this.value,
    required this.unit,
    this.badges = const <Widget>[],
    this.valueColor,
    this.fontSize = 56,
    this.sparkline = const <double>[],
    this.sparklineColor,
    this.barFraction,
    this.barColor,
    this.note,
    super.key,
  });

  final String label;
  final String value;
  final String unit;
  final List<Widget> badges;
  final Color? valueColor;
  final double fontSize;
  final List<double> sparkline;
  final Color? sparklineColor;
  final double? barFraction;
  final Color? barColor;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final color = valueColor ?? AutomotiveColors.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AutomotiveTextStyles.labelCaps.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                ),
              ),
            ),
            for (final badge in badges)
              Padding(
                padding: const EdgeInsets.only(left: AutomotiveSpacing.x0_5),
                child: badge,
              ),
          ],
        ),
        const SizedBox(height: AutomotiveSpacing.x0_5),
        // O valor encolhe em vez de estourar: a mesma tela roda em 1080p no carro e
        // em viewports pequenos nos testes, e cortar dígito de velocidade é pior que
        // desenhá-la menor.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: AutomotiveTextStyles.metricDisplay.copyWith(
                  color: color,
                  fontSize: fontSize,
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: AutomotiveSpacing.x1),
                Text(
                  unit,
                  style: AutomotiveTextStyles.unitLabel.copyWith(
                    color: AutomotiveColors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (barFraction != null) ...[
          const SizedBox(height: AutomotiveSpacing.x1),
          SocBar(fraction: barFraction!, color: barColor, height: 10),
        ],
        if (sparkline.length >= 2) ...[
          const SizedBox(height: AutomotiveSpacing.x1),
          SizedBox(
            height: 34,
            child: Sparkline(values: sparkline, color: sparklineColor ?? color),
          ),
        ],
        if (note != null) ...[
          const SizedBox(height: AutomotiveSpacing.x0_5),
          Text(
            note!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AutomotiveTextStyles.unitLabel.copyWith(
              color: AutomotiveColors.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }
}

/// Conta vertical do SOC: valor inicial, variação assinada e valor atual.
class LiveSocEquation extends StatelessWidget {
  const LiveSocEquation({
    required this.label,
    required this.startLabel,
    required this.deltaLabel,
    required this.currentLabel,
    required this.startValue,
    required this.deltaValue,
    required this.currentValue,
    this.badges = const <Widget>[],
    this.deltaPositive,
    super.key,
  });

  final String label;
  final String startLabel;
  final String deltaLabel;
  final String currentLabel;
  final String startValue;
  final String deltaValue;
  final String currentValue;
  final List<Widget> badges;
  final bool? deltaPositive;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AutomotiveTextStyles.labelCaps.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                ),
              ),
            ),
            for (final badge in badges)
              Padding(
                padding: const EdgeInsets.only(left: AutomotiveSpacing.x0_5),
                child: badge,
              ),
          ],
        ),
        const SizedBox(height: AutomotiveSpacing.x1),
        _SocEquationRow(label: startLabel, value: startValue),
        const SizedBox(height: AutomotiveSpacing.x0_5),
        _SocEquationRow(
          label: deltaLabel,
          value: deltaValue,
          valueColor: switch (deltaPositive) {
            true => AutomotiveColors.secondary,
            false => AutomotiveColors.warning,
            null => AutomotiveColors.onSurfaceVariant,
          },
        ),
        const Divider(height: AutomotiveSpacing.x1_5),
        _SocEquationRow(
          label: currentLabel,
          value: currentValue,
          valueColor: AutomotiveColors.batteryPositive,
          emphasized: true,
        ),
      ],
    );
  }
}

class _SocEquationRow extends StatelessWidget {
  const _SocEquationRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: AutomotiveColors.onSurfaceVariant,
              fontSize: 10,
            ),
          ),
        ),
        const SizedBox(width: AutomotiveSpacing.x2),
        Text(
          value,
          style: AutomotiveTextStyles.metricDisplay.copyWith(
            color: valueColor ?? AutomotiveColors.onSurface,
            fontSize: emphasized ? 38 : 28,
          ),
        ),
      ],
    );
  }
}

/// Linha compacta da coluna de sinais: rótulo à esquerda, valor mono à direita.
class LiveRailMetric extends StatelessWidget {
  const LiveRailMetric({
    required this.label,
    required this.value,
    this.badge,
    this.valueColor,
    this.barFraction,
    this.barColor,
    super.key,
  });

  final String label;
  final String value;
  final Widget? badge;
  final Color? valueColor;
  final double? barFraction;
  final Color? barColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.x1_5,
        vertical: AutomotiveSpacing.x1,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AutomotiveColors.outlineVariant),
        ),
      ),
      // Rótulo e selo numa linha, valor na de baixo: os nomes de sinal deste carro
      // são longos e o valor carrega unidade, então a versão em linha única só cabe
      // até alguém traduzir o rótulo — e aí corta o número, que é o que importa.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AutomotiveTextStyles.labelCaps.copyWith(
                    color: AutomotiveColors.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: AutomotiveSpacing.x0_5),
                badge!,
              ],
            ],
          ),
          const SizedBox(height: AutomotiveSpacing.x0_5),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              value,
              maxLines: 1,
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: valueColor ?? AutomotiveColors.onSurface,
                fontSize: 15,
              ),
            ),
          ),
          if (barFraction != null) ...[
            const SizedBox(height: AutomotiveSpacing.x0_5),
            SocBar(fraction: barFraction!, color: barColor, height: 4),
          ],
        ],
      ),
    );
  }
}

/// Faixa de avisos da tela: ponte CAN fora, fonte parada, erro do stream.
class LiveTripBanner extends StatelessWidget {
  const LiveTripBanner({required this.message, required this.color, super.key});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.marginScreen,
        vertical: AutomotiveSpacing.x1,
      ),
      child: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AutomotiveTextStyles.labelCaps.copyWith(color: color),
      ),
    );
  }
}

/// Ponto pulsante de "estamos recebendo dados".
///
/// A animação é curta e periférica de propósito: a diretriz do projeto é não
/// distrair dirigindo, mas uma tela ao vivo sem nenhum sinal de vida é
/// indistinguível de uma tela congelada.
class LivePulse extends StatefulWidget {
  const LivePulse({required this.label, required this.active, super.key});

  final String label;
  final bool active;

  @override
  State<LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<LivePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(LivePulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.active
        ? AutomotiveColors.secondary
        : AutomotiveColors.outline;
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.x1_5,
        vertical: AutomotiveSpacing.x0_5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween<double>(begin: 0.25, end: 1).animate(_controller),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                borderRadius: AutomotiveRadii.fullRadius,
              ),
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x1),
          Text(
            widget.label,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: color,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}
