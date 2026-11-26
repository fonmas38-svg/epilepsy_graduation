import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../core/enums.dart';
import '../models/models.dart';

/// The four physiological phases of a complete seizure event.
/// Used to drive the simulator through a realistic timeline rather than
/// snapping instantly between risk labels.
enum SeizurePhase {
  /// Between seizures — calm baseline (RiskLabel.stable).
  interictal,

  /// Early pre-onset changes — EEG/HR creeping up (RiskLabel.watch).
  preIctal,

  /// Active seizure — full discharges, tachycardia, movement (RiskLabel.highRisk).
  ictal,

  /// Recovery — signals returning to baseline (RiskLabel.stable with fatigue pattern).
  postIctal,
}

extension SeizurePhaseX on SeizurePhase {
  RiskLabel get riskLabel => switch (this) {
    SeizurePhase.interictal => RiskLabel.stable,
    SeizurePhase.preIctal => RiskLabel.watch,
    SeizurePhase.ictal => RiskLabel.highRisk,
    SeizurePhase.postIctal => RiskLabel.stable,
  };

  String get arabicLabel => switch (this) {
    SeizurePhase.interictal => 'بين النوبات',
    SeizurePhase.preIctal => 'ما قبل النوبة',
    SeizurePhase.ictal => 'أثناء النوبة',
    SeizurePhase.postIctal => 'ما بعد النوبة',
  };
}

/// Controls progression through a complete seizure cycle.
/// Call [nextPhase] on each tick; the cycle is:
///   interictal (N ticks) → preIctal (M ticks) → ictal (P ticks)
///   → postIctal (Q ticks) → interictal …
class SeizureCycleController {
  SeizureCycleController({
    this.interictalTicks = 5,
    this.preIctalTicks = 2,
    this.ictalTicks = 3,
    this.postIctalTicks = 2,
  });

  final int interictalTicks;
  final int preIctalTicks;
  final int ictalTicks;
  final int postIctalTicks;

  SeizurePhase _phase = SeizurePhase.interictal;
  int _phaseTickCount = 0;

  SeizurePhase get currentPhase => _phase;

  /// Returns the pattern for the CURRENT tick, then advances the counter.
  RiskLabel advance() {
    final label = _phase.riskLabel;
    _phaseTickCount++;
    final limit = switch (_phase) {
      SeizurePhase.interictal => interictalTicks,
      SeizurePhase.preIctal => preIctalTicks,
      SeizurePhase.ictal => ictalTicks,
      SeizurePhase.postIctal => postIctalTicks,
    };
    if (_phaseTickCount >= limit) {
      _phaseTickCount = 0;
      _phase = switch (_phase) {
        SeizurePhase.interictal => SeizurePhase.preIctal,
        SeizurePhase.preIctal => SeizurePhase.ictal,
        SeizurePhase.ictal => SeizurePhase.postIctal,
        SeizurePhase.postIctal => SeizurePhase.interictal,
      };
    }
    return label;
  }

  /// Jump directly to a specific phase (used by the UI escalation buttons).
  void forcePhase(SeizurePhase phase) {
    _phase = phase;
    _phaseTickCount = 0;
  }

  /// Reset to the beginning of the cycle.
  void reset() {
    _phase = SeizurePhase.interictal;
    _phaseTickCount = 0;
  }
}

class SignalSimulator {
  SignalSimulator({Random? random}) : _rng = random ?? Random();

  static const sampleRateHz = 256;
  static const defaultSamples = 262;
  final Random _rng;
  int _sampleIndex = 0;
  final _uuid = const Uuid();

  /// Deterministic pattern selector used by legacy tests and cyclical runners.
  RiskLabel patternForTick(int tick) {
    final mod = tick % 8;
    if (mod == 3 || mod == 6) return RiskLabel.watch;
    if (mod == 4 || mod == 5) return RiskLabel.highRisk;
    return RiskLabel.stable;
  }

  /// Generates a [VitalReading] for the given [pattern].
  VitalReading generate({
    required String patientId,
    RiskLabel pattern = RiskLabel.stable,
    int samples = defaultSamples,
  }) {
    RangeError.checkValueInInterval(samples, 8, 4096, 'samples');
    final eeg = <double>[];
    final ecg = <double>[];
    final motion = <double>[];
    late double hr;

    for (var i = 0; i < samples; i++) {
      final t = (_sampleIndex + i) / sampleRateHz * 2 * pi;
      switch (pattern) {
        case RiskLabel.stable:
          eeg.add(0.4 * sin(8 * t) + _n(0.1));
          ecg.add(_synthesizeEcg(t, rate: 2.2, noise: 0.03));
          motion.add(_n(0.15));
          hr = 70 + _n(3);
        case RiskLabel.watch:
          eeg.add(0.7 * sin(12 * t) + _n(0.25));
          ecg.add(
            _synthesizeEcg(t, rate: 2.8, noise: 0.05, ampMultiplier: 1.15),
          );
          motion.add(0.45 * sin(3 * t) + _n(0.2));
          hr = 95 + _n(6);
        case RiskLabel.highRisk:
          final burst = sin(25 * t) > 0.6 ? 0.8 : 0.0;
          eeg.add(1.4 * sin(20 * t) + burst + _n(0.35));
          ecg.add(
            _synthesizeEcg(t, rate: 3.8, noise: 0.08, ampMultiplier: 1.3),
          );
          motion.add(1.2 * sin(10 * t).abs() + _n(0.5));
          hr = 125 + _n(10);
      }
    }

    _sampleIndex += samples;
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

  /// Generates a [VitalReading] for a specific seizure [phase].
  /// Post-ictal uses a special "fatigue" pattern: low-amplitude slow waves
  /// and bradycardia (below normal) reflecting post-seizure exhaustion.
  VitalReading generateForPhase({
    required String patientId,
    required SeizurePhase phase,
    int samples = defaultSamples,
  }) {
    if (phase == SeizurePhase.postIctal) {
      return _generatePostIctal(patientId: patientId, samples: samples);
    }
    return generate(
      patientId: patientId,
      pattern: phase.riskLabel,
      samples: samples,
    );
  }

  /// Post-ictal: slow delta waves, suppressed amplitude, HR below normal.
  VitalReading _generatePostIctal({
    required String patientId,
    int samples = defaultSamples,
  }) {
    RangeError.checkValueInInterval(samples, 8, 4096, 'samples');
    final eeg = <double>[];
    final ecg = <double>[];
    final motion = <double>[];
    late double hr;

    for (var i = 0; i < samples; i++) {
      final t = (_sampleIndex + i) / sampleRateHz * 2 * pi;
      // Slow delta waves (1-4 Hz), suppressed amplitude — post-ictal exhaustion
      eeg.add(0.25 * sin(3 * t) + _n(0.08));
      ecg.add(_synthesizeEcg(t, rate: 1.8, noise: 0.02, ampMultiplier: 0.85));
      motion.add(_n(0.05)); // nearly motionless
      hr = 58 + _n(4); // slight bradycardia post-seizure
    }

    _sampleIndex += samples;
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

  /// One reading on a continuous interictal→preictal→onset ramp, mirroring the
  /// backend `make_trajectory_batch`. [progress] in [0,1] blends the calm
  /// `stable` morphology into the `high_risk` one so the offline forecast rises
  /// smoothly for a synthetic demonstration, without clinical forecasting evidence.
  VitalReading generateTrajectory({
    required String patientId,
    required double progress,
    int samples = defaultSamples,
  }) {
    if (!progress.isFinite) throw ArgumentError.value(progress, 'progress');
    final p = progress.clamp(0.0, 1.0).toDouble();
    RangeError.checkValueInInterval(samples, 8, 4096, 'samples');
    final eeg = <double>[];
    final ecg = <double>[];
    final motion = <double>[];
    late double hr;
    for (var i = 0; i < samples; i++) {
      final t = (_sampleIndex + i) / sampleRateHz * 2 * pi;
      final burst = sin(25 * t) > 0.6 ? 0.8 * p : 0.0;
      eeg.add(
        _lerp(0.4, 1.4, p) * sin(_lerp(8, 20, p) * t) +
            burst +
            _n(0.1 + 0.25 * p),
      );
      ecg.add(
        _synthesizeEcg(
          t,
          rate: _lerp(2.2, 3.8, p),
          noise: 0.03 + 0.05 * p,
          ampMultiplier: _lerp(1.0, 1.3, p),
        ),
      );
      motion.add(
        _lerp(0.0, 1.2, p) * sin(_lerp(3, 10, p) * t).abs() +
            _n(0.15 + 0.35 * p),
      );
      hr = _lerp(70, 125, p) + _n(3 + 7 * p);
    }
    _sampleIndex += samples;
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

List<double> decodeSignal(String raw) => List<double>.from(
  (jsonDecode(raw) as List).map((e) => (e as num).toDouble()),
);
