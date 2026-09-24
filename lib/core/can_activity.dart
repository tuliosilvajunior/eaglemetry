import 'can_bridge_models.dart';

/// Estado de atividade de um sinal CAN.
///
/// O que interessa aqui não é o valor, é **se e com que frequência ele muda**: a
/// maior parte dos 815 sinais do barramento fica parada ou zerada o tempo todo, e
/// achar os poucos que reagem a alguma coisa é o trabalho real.
///
/// A detecção usa o `ts_ns` do snapshot (contrato v2 = instante da última mudança),
/// não a comparação de valores. Isso evita o falso negativo clássico: um sinal que
/// vai de A para B e volta para A entre duas amostras mudou duas vezes, e comparar
/// só os valores diria que nada aconteceu.
class CanSignalActivity {
  CanSignalActivity({
    required this.index,
    required this.name,
    required this.canId,
    required this.unit,
    this.retainHistory = true,
    this.trackRate = true,
  });

  final int index;
  final String name;
  final int canId;
  final String unit;
  final bool retainHistory;
  final bool trackRate;

  double value = 0;
  int raw = 0;
  bool valid = false;
  bool calibrated = false;

  /// `ts_ns` da última mudança, como o daemon reportou.
  int lastChangeTsNs = -1;

  /// Relógio local do momento em que percebemos a mudança. É o que alimenta o
  /// "mudou há X" — o `ts_ns` é `CLOCK_MONOTONIC` do daemon e não é comparável
  /// com o relógio do app.
  int lastChangeAtMs = 0;

  int changeCount = 0;

  bool get everChanged => changeCount > 0;

  /// Amostras guardadas apenas quando o valor muda, para a sparkline mostrar a
  /// forma do sinal em vez de uma reta cheia de repetições.
  final List<double> history = <double>[];

  final List<int> _recentChangesMs = <int>[];

  /// Mudanças por segundo na janela de [rateWindow].
  double get changesPerSecond =>
      _recentChangesMs.length / (rateWindow.inMilliseconds / 1000);

  static const Duration rateWindow = Duration(seconds: 5);
  static const int historyLimit = 120;

  /// Incorpora uma leitura. Devolve true se o sinal mudou nesta amostra.
  bool observe({
    required double newValue,
    required int newRaw,
    required int tsNs,
    required bool isValid,
    required bool isCalibrated,
    required int nowMs,
  }) {
    value = newValue;
    raw = newRaw;
    valid = isValid;
    calibrated = isCalibrated;

    // Primeira leitura estabelece a linha de base: não é mudança.
    if (lastChangeTsNs < 0) {
      lastChangeTsNs = tsNs;
      if (retainHistory) history.add(newValue);
      return false;
    }
    if (tsNs == lastChangeTsNs) {
      if (trackRate) _trimRate(nowMs);
      return false;
    }

    lastChangeTsNs = tsNs;
    lastChangeAtMs = nowMs;
    changeCount++;
    if (trackRate) {
      _recentChangesMs.add(nowMs);
      _trimRate(nowMs);
    }

    if (retainHistory) {
      history.add(newValue);
      if (history.length > historyLimit) {
        history.removeAt(0);
      }
    }
    return true;
  }

  void _trimRate(int nowMs) {
    final cutoff = nowMs - rateWindow.inMilliseconds;
    while (_recentChangesMs.isNotEmpty && _recentChangesMs.first < cutoff) {
      _recentChangesMs.removeAt(0);
    }
  }

  /// Há quanto tempo mudou pela última vez, ou null se nunca mudou.
  Duration? ageSince(int nowMs) =>
      everChanged ? Duration(milliseconds: nowMs - lastChangeAtMs) : null;

  void reset() {
    lastChangeTsNs = -1;
    lastChangeAtMs = 0;
    changeCount = 0;
    history.clear();
    _recentChangesMs.clear();
  }
}

/// Como a lista de sinais é ordenada.
enum CanActivitySort {
  /// Quem mudou mais recentemente primeiro — o padrão, porque responde
  /// "o que acabou de reagir ao que eu fiz?".
  recency,

  /// Quem muda mais vezes por segundo primeiro.
  rate,

  /// Alfabética, para quando se procura um sinal específico.
  name,
}

/// Coleção de [CanSignalActivity] com busca, ordenação e silenciamento.
///
/// Puro Dart de propósito: nada aqui toca FFI, então dá para testar a lógica de
/// detecção sem um carro e sem o daemon.
class CanActivityTracker {
  CanActivityTracker({
    required List<RoadcastSchemaEntry> entries,
    Set<String>? muted,
    bool retainHistory = true,
    bool trackRate = true,
  }) : signals = entries
           .map(
             (entry) => CanSignalActivity(
               index: entry.index,
               name: entry.name,
               canId: entry.canId,
               unit: entry.unit,
               retainHistory: retainHistory,
               trackRate: trackRate,
             ),
           )
           .toList(growable: false),
       _muted = {...?muted};

  final List<CanSignalActivity> signals;
  final Set<String> _muted;

  /// Sinais que mudam por construção e não dizem nada sobre o carro.
  ///
  /// `AliveCounter` incrementa a cada transmissão do frame e `Checksum` muda junto
  /// com ele; os relógios do IPK avançam sozinhos. Deixá-los soltos numa tela cujo
  /// propósito é "o que está mudando" garante que os primeiros lugares do ranking
  /// sejam sempre ruído.
  static const List<String> noisyNameParts = [
    'Checksum',
    'AliveCounter',
    'IPK_Second',
    'IPK_Minute',
  ];

  static bool isNoisy(String name) {
    final lower = name.toLowerCase();
    return noisyNameParts.any((part) => lower.contains(part.toLowerCase()));
  }

  /// Nomes ruidosos presentes nesta tabela — usados para semear o silenciamento
  /// na primeira execução, deixando o usuário livre para reativá-los depois.
  List<String> noisySignalNames() => signals
      .where((signal) => isNoisy(signal.name))
      .map((signal) => signal.name)
      .toList(growable: false);

  /// Índices na ordem em que [observe] espera receber as leituras.
  List<int> get indices =>
      signals.map((signal) => signal.index).toList(growable: false);

  Set<String> get muted => Set.unmodifiable(_muted);

  int get mutedCount => _muted.length;

  /// Quantos sinais já mudaram alguma vez desde o início (ou desde [resetAll]).
  int get changedCount => signals.where((signal) => signal.everChanged).length;

  /// Quantos mudaram na última janela de tempo — a métrica "está vivo agora".
  int activeCount(int nowMs, {Duration within = const Duration(seconds: 2)}) =>
      signals
          .where(
            (signal) =>
                signal.everChanged &&
                nowMs - signal.lastChangeAtMs <= within.inMilliseconds,
          )
          .length;

  /// Incorpora uma leitura em lote. A ordem de [reading] tem que ser a de
  /// [indices] — é o mesmo contrato posicional do snapshot.
  void observe(CanBridgeReading reading, int nowMs) {
    final count = reading.length < signals.length
        ? reading.length
        : signals.length;
    for (var i = 0; i < count; i++) {
      signals[i].observe(
        newValue: reading.valueAt(i),
        newRaw: reading.rawAt(i),
        tsNs: reading.timestampNsAt(i),
        isValid: reading.isValidAt(i),
        isCalibrated: reading.isCalibratedAt(i),
        nowMs: nowMs,
      );
    }
  }

  bool isMuted(String name) => _muted.contains(name);

  void mute(String name) => _muted.add(name);

  void unmute(String name) => _muted.remove(name);

  void unmuteAll() => _muted.clear();

  void resetAll() {
    for (final signal in signals) {
      signal.reset();
    }
  }

  /// Lista filtrada e ordenada para exibição.
  ///
  /// [onlyChanging] esconde o que nunca mudou, que é a maioria e o que polui a
  /// tela. [showMuted] traz de volta os silenciados, para poder reativá-los.
  List<CanSignalActivity> ranked({
    String query = '',
    bool onlyChanging = true,
    bool showMuted = false,
    CanActivitySort sort = CanActivitySort.recency,
    bool validOnly = false,
  }) {
    final needle = query.trim().toLowerCase();
    final canIdQuery = needle.isEmpty ? null : int.tryParse(needle, radix: 16);

    final filtered = signals.where((signal) {
      if (_muted.contains(signal.name) != showMuted) return false;
      if (onlyChanging && !signal.everChanged) return false;
      if (validOnly && !signal.valid) return false;
      if (needle.isEmpty) return true;
      return signal.name.toLowerCase().contains(needle) ||
          signal.canId == canIdQuery;
    }).toList();

    switch (sort) {
      case CanActivitySort.recency:
        filtered.sort((a, b) {
          final byRecency = b.lastChangeAtMs.compareTo(a.lastChangeAtMs);
          if (byRecency != 0) return byRecency;
          return b.changeCount.compareTo(a.changeCount);
        });
      case CanActivitySort.rate:
        filtered.sort((a, b) {
          final byRate = b.changesPerSecond.compareTo(a.changesPerSecond);
          if (byRate != 0) return byRate;
          return b.lastChangeAtMs.compareTo(a.lastChangeAtMs);
        });
      case CanActivitySort.name:
        filtered.sort((a, b) => a.name.compareTo(b.name));
    }
    return filtered;
  }

  /// Sinal mais ativo não silenciado — usado para escolher sozinho o que mostrar
  /// no gauge quando o usuário ainda não escolheu nada.
  CanSignalActivity? mostActive() {
    CanSignalActivity? best;
    for (final signal in signals) {
      if (_muted.contains(signal.name) || !signal.everChanged) continue;
      if (best == null || signal.changeCount > best.changeCount) {
        best = signal;
      }
    }
    return best;
  }

  CanSignalActivity? byName(String name) {
    for (final signal in signals) {
      if (signal.name == name) return signal;
    }
    return null;
  }
}
