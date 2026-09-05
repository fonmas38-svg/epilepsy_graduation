import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../core/enums.dart';
import '../models/models.dart';

class SignalSimulator {
  SignalSimulator({Random? random}) : _rng = random ?? Random();

  final Random _rng;
  final _uuid = const Uuid();

  VitalReading generate({
    required String patientId,
    RiskLabel pattern = RiskLabel.stable,
    int samples = 64,
  }) {
    final eeg = <double>[];
    final ecg = <double>[];
    final motion = <double>[];
    late double hr;

    for (var i = 0; i < samples; i++) {
      final t = i / samples * 2 * pi;
      switch (pattern) {
        case RiskLabel.stable:
          eeg.add(0.4 * sin(8 * t) + _n(0.1));
          ecg.add(_synthesizeEcg(t, rate: 2.2, noise: 0.03));
          motion.add(_n(0.15));
          hr = 70 + _n(3);
        case RiskLabel.watch:
          eeg.add(0.7 * sin(12 * t) + _n(0.25));
          ecg.add(_synthesizeEcg(t, rate: 2.8, noise: 0.05, ampMultiplier: 1.15));
          motion.add(0.45 * sin(3 * t) + _n(0.2));
          hr = 95 + _n(6);
        case RiskLabel.highRisk:
          final burst = sin(25 * t) > 0.6 ? 0.8 : 0.0;
          eeg.add(1.4 * sin(20 * t) + burst + _n(0.35));
          ecg.add(_synthesizeEcg(t, rate: 3.8, noise: 0.08, ampMultiplier: 1.3));
          motion.add(1.2 * sin(10 * t).abs() + _n(0.5));
          hr = 125 + _n(10);
      }
    }

    return VitalReading(
      id: _uuid.v4(),
      patientId: patientId,
      timestamp: DateTime.now(),
      eeg: eeg,
      ecg: ecg,
      motion: motion,
      hr: hr,
    );
  }

  /// Cycles patterns so demos show stable -> watch -> high_risk over time.
  RiskLabel patternForTick(int tick) {
    final m = tick % 5;
    if (m == 4) return RiskLabel.highRisk;
    if (m == 2 || m == 3) return RiskLabel.watch;
    return RiskLabel.stable;
  }

  /// One reading on a continuous interictal→preictal→onset ramp, mirroring the
  /// backend `make_trajectory_batch`. [progress] in [0,1] blends the calm
  /// `stable` morphology into the `high_risk` one so the offline forecast rises
  /// smoothly (the app *predicting* an approaching seizure with no server).
  VitalReading generateTrajectory({
    required String patientId,
    required double progress,
    int samples = 64,
  }) {
    final p = progress.clamp(0.0, 1.0).toDouble();
    final eeg = <double>[];
    final ecg = <double>[];
    final motion = <double>[];
    late double hr;
    for (var i = 0; i < samples; i++) {
      final t = i / samples * 2 * pi;
      final burst = sin(25 * t) > 0.6 ? 0.8 * p : 0.0;
      eeg.add(_lerp(0.4, 1.4, p) * sin(_lerp(8, 20, p) * t) + burst + _n(0.1 + 0.25 * p));
      ecg.add(_synthesizeEcg(t, rate: _lerp(2.2, 3.8, p), noise: 0.03 + 0.05 * p, ampMultiplier: _lerp(1.0, 1.3, p)));
      motion.add(_lerp(0.0, 1.2, p) * sin(_lerp(3, 10, p) * t).abs() + _n(0.15 + 0.35 * p));
      hr = _lerp(70, 125, p) + _n(3 + 7 * p);
    }
    return VitalReading(
      id: _uuid.v4(),
      patientId: patientId,
      timestamp: DateTime.now(),
      eeg: eeg,
      ecg: ecg,
      motion: motion,
      hr: hr,
    );
  }

  /// Synthesize authentic physiological P-Q-R-S-T electrocardiogram waveform.
  double _synthesizeEcg(
    double t, {
    double rate = 2.2,
    double noise = 0.03,
    double ampMultiplier = 1.0,
  }) {
    final cycle = (t * rate / (2 * pi)) % 1.0;

    // Gaussian wave component helper
    double g(double mean, double width, double amp) {
      final d = cycle - mean;
      return amp * ampMultiplier * exp(-0.5 * (d * d) / (width * width));
    }

    final p = g(0.18, 0.045, 0.22); // Atrial P wave
    final q = g(0.32, 0.015, -0.18); // Q dip
    final r = g(0.36, 0.020, 1.65); // R spike (ventricular depolarization)
    final s = g(0.40, 0.022, -0.38); // S dip
    final tw = g(0.60, 0.065, 0.38); // T wave (ventricular repolarization)

    return p + q + r + s + tw + _n(noise);
  }

  /// Progress in [0,1] for a slow offline ramp: climbs over ~[rampTicks] ticks,
  /// then holds at onset. Pair with [generateTrajectory].
  double trajectoryProgressForTick(int tick, {int rampTicks = 12}) {
    if (rampTicks <= 0) return 1.0;
    final v = tick / rampTicks;
    return v < 1.0 ? v : 1.0;
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  double _n(double scale) => (_rng.nextDouble() * 2 - 1) * scale;
}

String encodeSignal(List<double> values) => jsonEncode(values);

List<double> decodeSignal(String raw) =>
    List<double>.from((jsonDecode(raw) as List).map((e) => (e as num).toDouble()));
