import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/live_roadcast_runtime.dart';
import '../core/live_trip_can.dart';
import '../core/live_trip_can_hub.dart';
import '../core/telemetry_format.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// O cartão de inclinação da via, para o rodapé de leitura instantânea da
/// shell.
///
/// A fonte é `ESC_RoadInclnRoadIncln` no barramento, medido pelo próprio carro,
/// e não mais o acelerómetro da head unit. A IMU media a inclinação do tablet:
/// o valor trazia o ângulo fixo do suporte somado ao da via, e nada o subtraía.
///
/// O sinal chega com o carro parado — medido no carro em 2026-08-10, cerca de
/// 20 atualizações por segundo com o veículo imóvel — portanto o cartão tem o
/// que mostrar fora de viagem, que é o motivo de ele viver no rodapé.
///
/// Como [EfficiencyReadout], ele se alimenta sozinho e para de amostrar quando
/// um cartão em tela cheia empurra o rodapé para fora da tela.
class InclineReadout extends StatefulWidget {
  const InclineReadout({
    this.stage,
    this.inclineSource,
    this.liveCan,
    this.samplingEnabled = true,
    super.key,
  });

  /// O estágio de cartões da shell, observado para parar a amostragem enquanto
  /// o rodapé está fora da tela.
  final CardStageController? stage;

  /// Costura de teste. Em produção o widget monta o seu próprio
  /// [LiveRoadcastRuntime]. O valor é o ângulo da via em graus, ou nulo quando
  /// o barramento não o entrega calibrado.
  final ValueListenable<double?>? inclineSource;

  /// Cliente 60 Hz partilhado com o cartão de eficiência. Nulo nos testes,
  /// que então abrem um runtime privado ou usam [inclineSource].
  final LiveTripCanHub? liveCan;

  /// Falso quando o rodapé está fora da tela por um motivo que este cartão
  /// não possui (History a tomar a faixa).
  final bool samplingEnabled;

  @override
  State<InclineReadout> createState() => _InclineReadoutState();
}

class _InclineReadoutState extends State<InclineReadout>
    with WidgetsBindingObserver {
  /// Abaixo disto a mudança não altera o desenho nem o rótulo, que arredonda
  /// para grau inteiro. Parado o sinal oscila cerca de ±0,23°, e republicar
  /// cada oscilação só produziria repintura.
  static const _degreeEpsilon = 0.05;

  LiveRoadcastRuntime<LiveTripCanState>? _live;

  /// O ângulo publicado para o cartão. Um notificador, e não um campo, para que
  /// a reconstrução pare no cartão em vez de subir até a shell.
  late final ValueNotifier<double?> _ownAngle = ValueNotifier<double?>(null);

  bool _sampling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A fonte injetada passa pelo mesmo [_publish] que o barramento, e não
    // direto ao cartão. É o que faz a pausa valer para as duas: um teste que
    // exercita a pausa exercita o caminho que roda no carro.
    widget.inclineSource?.addListener(_onSourceChanged);
    if (widget.inclineSource == null && widget.liveCan == null) {
      // A watchlist inteira da viagem, e não só a inclinação. A leitura é uma
      // travessia FFI em lote de qualquer forma, e uma lista privada mais curta
      // seria um segundo lugar onde manter os nomes dos sinais corretos.
      _live = LiveRoadcastRuntime<LiveTripCanState>(
        watchlist: LiveTripCanNames.watchlist,
        createState: (entries) =>
            LiveTripCanState(entries: entries, retainActivityHistory: false),
        observeSample: (state, reading, nowMillis) {
          state.observe(reading, nowMillis);
          _publish(state.roadInclineDegrees);
        },
      );
    }
    widget.stage?.addListener(_onStageChanged);
    _resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.inclineSource?.removeListener(_onSourceChanged);
    widget.stage?.removeListener(_onStageChanged);
    _pause();
    _live?.dispose();
    _ownAngle.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant InclineReadout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.samplingEnabled != widget.samplingEnabled) {
      if (widget.samplingEnabled) {
        _resume();
      } else {
        _pause();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else {
      _pause();
    }
  }

  /// O cartão está oculto exatamente quando um cartão de baixo tomou a tela
  /// inteira. Qualquer coisa aquém disso deixa parte da faixa visível, então
  /// ele continua a ler.
  void _onStageChanged() {
    if (widget.stage?.isFullscreen ?? false) {
      _pause();
    } else {
      _resume();
    }
  }

  void _onSourceChanged() => _publish(widget.inclineSource?.value);

  void _onCanSample(LiveTripCanState state, int _) {
    _publish(state.roadInclineDegrees);
  }

  /// Publica o ângulo, ignorando o ruído que não muda o desenho.
  ///
  /// A ausência nunca é filtrada: o barramento calar é um fato sobre o carro, e
  /// tem de chegar ao cartão no mesmo instante.
  void _publish(double? degrees) {
    if (!_sampling) return;
    final current = _ownAngle.value;
    if (degrees == null || current == null) {
      _ownAngle.value = degrees;
      return;
    }
    if ((degrees - current).abs() < _degreeEpsilon) return;
    _ownAngle.value = degrees;
  }

  void _resume() {
    if (_sampling || !mounted) return;
    if (!widget.samplingEnabled) return;
    if (widget.stage?.isFullscreen ?? false) return;
    _sampling = true;
    final hub = widget.liveCan;
    if (hub != null) {
      hub.addListener(_onCanSample);
      unawaited(hub.acquire());
    } else {
      unawaited(_live?.start());
    }
  }

  void _pause() {
    if (!_sampling) return;
    _sampling = false;
    final hub = widget.liveCan;
    if (hub != null) {
      hub.removeListener(_onCanSample);
      hub.release();
    } else {
      _live?.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return ValueListenableBuilder<double?>(
      valueListenable: _ownAngle,
      builder: (context, degrees, _) => TiltCard(
        label: loc.inclineReadoutTitle,
        value: tiltAngleLabel(degrees),
        angleDeg: degrees,
        silhouette: CarSilhouette.side,
      ),
    );
  }
}
