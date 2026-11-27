import 'package:flutter/foundation.dart';

import '../../core/enums.dart';

/// Which model produced a decision.
enum EvalEngine { cloud, phone }

/// One scored window: the simulator's truth next to the model's output.
class EvalRecord {
  const EvalRecord({
    required this.at,
    required this.engine,
    required this.episode,
    required this.truthSeizure,
    required this.truthPreIctal,
    required this.label,
    required this.predicted,
    required this.phase,
    required this.type,
  });

  final DateTime at;
  final EvalEngine engine;
  final int episode;
  final bool truthSeizure;
  final bool truthPreIctal;
  final RiskLabel label;
  final bool predicted;
  final String phase;
  final String? type;

  List<String> toCsv() => [
    at.toUtc().toIso8601String(),
    engine.name,
    '$episode',
    phase,
    type ?? '',
    truthSeizure ? '1' : '0',
    truthPreIctal ? '1' : '0',
    label.apiValue,
    predicted ? '1' : '0',
  ];
}

/// Accuracy of one engine over the recorded windows.
class EngineMetrics {
  EngineMetrics({
    required this.windows,
    required this.seizureEpisodes,
    required this.detectedEpisodes,
    required this.forecastEpisodes,
    required this.meanDetectionSeconds,
    required this.falseAlarms,
    required this.calmHours,
    required this.confusion,
  });

  final int windows;
  final int seizureEpisodes;
  final int detectedEpisodes;
  final int forecastEpisodes;
  final double? meanDetectionSeconds;
  final int falseAlarms;
  final double calmHours;

  /// truth (stable / pre_ictal / seizure) → predicted label → count.
  final Map<String, Map<String, int>> confusion;

  double? get sensitivity =>
      seizureEpisodes == 0 ? null : detectedEpisodes / seizureEpisodes;
  double? get forecastRate =>
      seizureEpisodes == 0 ? null : forecastEpisodes / seizureEpisodes;
  double? get falseAlarmsPerHour =>
      calmHours <= 0 ? null : falseAlarms / calmHours;
}

/// Compares what the virtual sensor really streamed with what each model
/// decided, for the cloud and the on-phone model separately. Kept in memory
/// (bounded) and exportable as CSV for the project report.
class ModelEvaluation extends ChangeNotifier {
  ModelEvaluation({this.windowSeconds = 2, this.capacity = 20000});

  final double windowSeconds;
  final int capacity;
  final List<EvalRecord> _records = [];

  List<EvalRecord> get records => List.unmodifiable(_records);

  void add(EvalRecord r) {
    _records.add(r);
    if (_records.length > capacity) _records.removeAt(0);
    notifyListeners();
  }

  void clear() {
    _records.clear();
    notifyListeners();
  }

  EngineMetrics metricsFor(EvalEngine engine) {
    final rows = _records.where((r) => r.engine == engine).toList();
    final confusion = <String, Map<String, int>>{};
    final seizureEpisodes = <int>{};
    final detected = <int, DateTime>{};
    final onset = <int, DateTime>{};
    final forecast = <int>{};
    var falseAlarms = 0;
    var calmWindows = 0;
    var prevAlarm = false;
    for (final r in rows) {
      final truth = r.truthSeizure
          ? 'seizure'
          : r.truthPreIctal
          ? 'pre_ictal'
          : 'stable';
      final row = confusion.putIfAbsent(truth, () => {});
      row[r.label.apiValue] = (row[r.label.apiValue] ?? 0) + 1;
      final alarm = r.label == RiskLabel.highRisk;
      if (r.truthSeizure) {
        seizureEpisodes.add(r.episode);
        onset.putIfAbsent(r.episode, () => r.at);
        if (alarm) detected.putIfAbsent(r.episode, () => r.at);
      } else {
        calmWindows++;
        // A new alarm while nothing is happening = one false alarm event.
        if (alarm && !prevAlarm && !r.truthPreIctal) falseAlarms++;
      }
      if (r.truthPreIctal && r.predicted) forecast.add(r.episode);
      prevAlarm = alarm;
    }
    final latencies = [
      for (final e in detected.keys)
        if (onset[e] != null)
          detected[e]!.difference(onset[e]!).inMilliseconds / 1000.0,
    ];
    return EngineMetrics(
      windows: rows.length,
      seizureEpisodes: seizureEpisodes.length,
      detectedEpisodes: detected.length,
      forecastEpisodes: forecast.where(seizureEpisodes.contains).length,
      meanDetectionSeconds: latencies.isEmpty
          ? null
          : latencies.reduce((a, b) => a + b) / latencies.length,
      falseAlarms: falseAlarms,
      calmHours: calmWindows * windowSeconds / 3600,
      confusion: confusion,
    );
  }

  String toCsv() {
    final lines = [
      'time,engine,episode,phase,seizure_type,truth_seizure,truth_preictal,model_label,model_forecast',
      for (final r in _records) r.toCsv().join(','),
    ];
    return lines.join('\n');
  }
}
