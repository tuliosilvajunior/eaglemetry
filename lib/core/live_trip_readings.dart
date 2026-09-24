import 'package:fl_chart/fl_chart.dart';

import 'telemetry_api.dart';
import 'telemetry_format.dart';

/// Qualidades que o store nativo usa para dizer que o valor não presta.
///
/// A lista é de recusa, não de aceitação: o mock web publica `FRESH`, que não existe
/// no enum nativo, e uma lista de aceitação apagaria a tela toda no mock em vez de
/// mostrar o que o carro mostraria.
const Set<String> kUnusableSignalQualities = {'UNAVAILABLE', 'ERROR'};

/// Leituras do caminho VHAL (property → coleta nativa → `EventChannel`).
///
/// **Aderentes**: cada campo guarda o último valor utilizável, porque as properties
/// chegam em cadências diferentes (velocidade a 5 Hz, SOC a cada 10 s) e zerar um
/// campo porque o frame atual não o trouxe faria a tela piscar `--` sem que o carro
/// tenha mudado de estado.
class LiveTripVhalReadings {
  const LiveTripVhalReadings({
    this.timestampMillis = 0,
    this.speedKmh,
    this.socPercent,
    this.odometerKm,
    this.gear,
    this.ambientTempC,
    this.packVoltageV,
    this.packCurrentA,
    this.vhalPowerKw,
    this.latitude,
    this.longitude,
    this.altitudeM,
    this.gpsAccuracyM,
    this.gpsFixAgeMillis,
    this.gpsEnabled,
    this.tripState,
  });

  final int timestampMillis;
  final double? speedKmh;
  final double? socPercent;
  final double? odometerKm;
  final int? gear;
  final double? ambientTempC;
  final double? packVoltageV;
  final double? packCurrentA;

  /// `EV_BATTERY_INSTANTANEOUS_POWER` (mW convertidos pela coleta). Fica aqui para
  /// comparação com o CAN, não como fonte de eficiência — ver AGENTS.md.
  final double? vhalPowerKw;

  final double? latitude;
  final double? longitude;
  final double? altitudeM;
  final double? gpsAccuracyM;
  final int? gpsFixAgeMillis;
  final bool? gpsEnabled;
  final String? tripState;

  bool get hasFix => latitude != null && longitude != null;

  /// Potência do pack por V×I. É medição derivada de dois sinais confiáveis, não a
  /// escala assumida do CAN — o sinal (carga/descarga) fica como vem, porque a
  /// convenção da corrente neste carro não foi confirmada.
  double? get packPowerKw {
    final volts = packVoltageV;
    final amps = packCurrentA;
    if (volts == null || amps == null) return null;
    return volts * amps / 1000;
  }

  /// Incorpora um frame preservando os valores que ele não trouxe.
  LiveTripVhalReadings merge(LiveTelemetryFrame frame) {
    final location = frame.location;
    final gpsFlag = location['gpsEnabled'];
    return LiveTripVhalReadings(
      timestampMillis: frame.timestampMillis > 0
          ? frame.timestampMillis
          : timestampMillis,
      speedKmh: _signal(frame, 'VEHICLE_SPEED') ?? speedKmh,
      socPercent: _signal(frame, 'HV_BATTERY_SOC') ?? socPercent,
      odometerKm: _signal(frame, 'ODOMETER') ?? odometerKm,
      gear: _signal(frame, 'GEAR')?.round() ?? gear,
      ambientTempC:
          _signal(frame, 'AMBIENT_AIR_TEMPERATURE') ??
          _signal(frame, 'OUTSIDE_TEMPERATURE') ??
          ambientTempC,
      packVoltageV: _signal(frame, 'HV_BATTERY_VOLTAGE') ?? packVoltageV,
      packCurrentA: _signal(frame, 'HV_BATTERY_CURRENT') ?? packCurrentA,
      vhalPowerKw:
          _signal(frame, 'EV_BATTERY_INSTANTANEOUS_POWER') ?? vhalPowerKw,
      latitude: mapDouble(location, 'latitude') ?? latitude,
      longitude: mapDouble(location, 'longitude') ?? longitude,
      altitudeM: mapDouble(location, 'altitudeM') ?? altitudeM,
      gpsAccuracyM: mapDouble(location, 'gpsAccuracyM') ?? gpsAccuracyM,
      gpsFixAgeMillis:
          mapDouble(location, 'lastFixAgeMillis')?.round() ?? gpsFixAgeMillis,
      gpsEnabled: gpsFlag is bool ? gpsFlag : gpsEnabled,
      tripState: mapText(frame.trip, 'tripState') ?? tripState,
    );
  }

  static double? _signal(LiveTelemetryFrame frame, String signalId) {
    for (final sample in frame.signals) {
      if (sample.signalId != signalId) continue;
      if (kUnusableSignalQualities.contains(sample.quality.toUpperCase())) {
        return null;
      }
      return objectAsDouble(sample.value);
    }
    return null;
  }
}

/// Janela deslizante de pontos para um gráfico ao vivo.
///
/// Duas decisões que a tela depende: a janela é por **tempo**, não por contagem, e a
/// entrada é decimada por [minStep]. A fonte CAN chega a 120 Hz; guardar tudo daria
/// dezenas de milhares de pontos para desenhar num painel de 300 px, que é trabalho
/// jogado fora e memória que cresce enquanto a viagem durar.
class LiveTripSeries {
  LiveTripSeries({
    this.window = const Duration(minutes: 10),
    this.minStep = const Duration(seconds: 1),
  });

  final Duration window;
  final Duration minStep;

  final List<FlSpot> _spots = <FlSpot>[];
  int? _referenceMillis;
  int _lastAcceptedMillis = 0;

  List<FlSpot> get spots => _spots;

  bool get isEmpty => _spots.isEmpty;

  /// Extremos em X (segundos desde a primeira amostra), para o gráfico não abrir um
  /// vão à esquerda quando a janela começa a descartar pontos antigos.
  double get minX => _spots.isEmpty ? 0 : _spots.first.x;

  double get maxX => _spots.isEmpty ? 1 : _spots.last.x;

  /// Devolve true quando o ponto entrou — é o que a tela usa para redesenhar os
  /// gráficos na cadência deles (1 Hz) em vez da cadência da amostragem (16 Hz).
  bool add(int timestampMillis, double? value) {
    if (value == null || !value.isFinite) return false;
    if (timestampMillis - _lastAcceptedMillis < minStep.inMilliseconds) {
      return false;
    }
    _lastAcceptedMillis = timestampMillis;
    final reference = _referenceMillis ??= timestampMillis;
    _spots.add(FlSpot((timestampMillis - reference) / 1000, value));

    final cutoff = (timestampMillis - reference - window.inMilliseconds) / 1000;
    if (cutoff <= 0) return true;
    var drop = 0;
    while (drop < _spots.length && _spots[drop].x < cutoff) {
      drop++;
    }
    // Nunca esvazia a série: o último ponto é o valor atual, e descartá-lo por causa
    // da janela apagaria o gráfico inteiro num intervalo sem amostras novas.
    if (drop >= _spots.length) drop = _spots.length - 1;
    if (drop > 0) _spots.removeRange(0, drop);
    return true;
  }

  void clear() {
    _spots.clear();
    _referenceMillis = null;
    _lastAcceptedMillis = 0;
  }
}
