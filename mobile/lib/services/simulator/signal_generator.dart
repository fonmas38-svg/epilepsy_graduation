import 'dart:math';
import 'dart:typed_data';

import 'seizure_library.dart';
import 'sim_types.dart';

/// One 262-sample window of all channels.
class SimSignals {
  const SimSignals({
    required this.eeg,
    required this.ecg,
    required this.motion,
    required this.hr,
  });

  final List<double> eeg;
  final List<double> ecg;
  final List<double> motion;
  final double hr;
}

/// Per-episode randomness, so no two seizures look the same.
class EpisodeStyle {
  EpisodeStyle(Random rng)
    : eegGain = 0.8 + rng.nextDouble() * 0.5,
      hrBase = 62 + rng.nextDouble() * 16,
      hrPeak = 110 + rng.nextDouble() * 35,
      motionGain = 0.6 + rng.nextDouble() * 0.6,
      noise = 0.03 + rng.nextDouble() * 0.05;

  final double eegGain;
  final double hrBase;
  final double hrPeak;
  final double motionGain;
  final double noise;
}

/// Builds every window from REAL EEG segments ([SeizureLibrary]) shaped by
/// the phase, the seizure type, the progress through the phase (0..1) and the
/// episode's own style. Heart rate, ECG and motion follow the physiology of
/// each phase. Nothing here labels the window: the models decide.
class SimSignalGenerator {
  SimSignalGenerator(this.library, {Random? random})
    : _rng = random ?? Random();

  /// Swappable: the synthetic fallback is replaced by the real library.
  SeizureLibrary library;
  final Random _rng;
  static const _n = SeizureLibrary.window;
  static const _fs = 256.0;
  double _ecgPhase = 0;
  double _hr = 70;

  SimSignals next({
    required SimPhase phase,
    required SimSeizureType type,
    required double progress,
    required EpisodeStyle style,
  }) {
    final p = progress.clamp(0.0, 1.0);
    final art = type == SimSeizureType.artifact;
    late Float64List eeg;
    late double hrTarget;
    late double motion;

    switch (phase) {
      case SimPhase.stable:
        eeg = _scaled(
          library.pick('baseline', _rng),
          0.9 + _rng.nextDouble() * 0.2,
        );
        hrTarget = style.hrBase;
        motion = 0.08;
      case SimPhase.preIctal:
        // Real pre-ictal EEG (CHB-MIT library) when available; otherwise
        // between-seizure activity of the epileptogenic zone (Bonn has no
        // pre-ictal recordings), slowly intensifying with rare short bursts.
        final realPre = !art && library.hasRealPreIctal;
        eeg = _scaled(
          library.pick(
            art ? 'baseline' : (realPre ? 'preictal' : 'interictal'),
            _rng,
          ),
          realPre ? 1.0 : 1.0 + 0.4 * p,
        );
        if (!art && !realPre && _rng.nextDouble() < 0.15 * p) {
          eeg = _blend(eeg, library.pick('ictal', _rng), 0.25 * p);
        }
        hrTarget = style.hrBase + (art ? 5 : 18) * p;
        motion = 0.1 + 0.1 * p;
      case SimPhase.onset:
        eeg = art
            ? _artifact(library.pick('baseline', _rng), 0.5 + 0.5 * p)
            : _blend(
                library.pick('interictal', _rng),
                _ictal(type, style, p),
                p,
              );
        hrTarget = _lerp(style.hrBase + 18, _ictalHr(type, style), p);
        motion = _ictalMotion(type, style) * p;
      case SimPhase.ictal:
        eeg = art
            ? _artifact(library.pick('baseline', _rng), 1.0)
            : _ictal(type, style, p);
        hrTarget = _ictalHr(type, style);
        motion = _ictalMotion(type, style);
      case SimPhase.offset:
        // Discharges fade into post-ictal suppression.
        eeg = art
            ? _artifact(library.pick('baseline', _rng), 1.0 - p)
            : _blend(
                _ictal(type, style, 1),
                _scaled(library.pick('baseline', _rng), 0.4),
                p,
              );
        hrTarget = _lerp(_ictalHr(type, style), style.hrBase + 10, p);
        motion = _ictalMotion(type, style) * (1 - p);
      case SimPhase.recovery:
        // Post-ictal: suppressed, slow (delta) activity returning to normal.
        eeg = _addSine(
          _scaled(library.pick('baseline', _rng), 0.45 + 0.55 * p),
          art ? 0 : 0.25 * (1 - p),
          2.0,
        );
        hrTarget = _lerp(style.hrBase + 10, style.hrBase, p);
        motion = 0.04;
    }

    for (var i = 0; i < _n; i++) {
      eeg[i] = eeg[i] * style.eegGain + style.noise * _gauss();
    }
    _hr += (hrTarget - _hr) * 0.35 + _gauss() * 1.2;
    return SimSignals(
      eeg: eeg,
      ecg: _ecg(_hr),
      motion: _motion(motion * style.motionGain, phase, type),
      hr: double.parse(_hr.toStringAsFixed(1)),
    );
  }

  Float64List _ictal(SimSeizureType type, EpisodeStyle style, double p) {
    switch (type) {
      case SimSeizureType.tonicClonic:
        return _scaled(library.pick('ictal', _rng), 1.2);
      case SimSeizureType.focal:
        return _blend(
          _scaled(library.pick('baseline', _rng), 1.4),
          library.pick('ictal', _rng),
          0.6,
        );
      case SimSeizureType.absence:
        // Generalized ~3 Hz spike-and-wave on a calm background.
        return _spikeWave(library.pick('baseline', _rng), 1.3, 3.0);
      case SimSeizureType.nocturnal:
        return _scaled(library.pick('ictal', _rng), 1.0);
      case SimSeizureType.gradual:
        return _scaled(library.pick('ictal', _rng), 0.5 + 0.8 * p);
      case SimSeizureType.artifact:
        return _artifact(library.pick('baseline', _rng), 1.0);
    }
  }

  double _ictalHr(SimSeizureType type, EpisodeStyle style) => switch (type) {
    SimSeizureType.tonicClonic => style.hrPeak + 10,
    SimSeizureType.focal => style.hrBase + 30,
    SimSeizureType.absence => style.hrBase + 5,
    SimSeizureType.nocturnal => style.hrBase - 6 + 40,
    SimSeizureType.gradual => style.hrPeak,
    SimSeizureType.artifact => style.hrBase + 15,
  };

  double _ictalMotion(SimSeizureType type, EpisodeStyle style) =>
      switch (type) {
        SimSeizureType.tonicClonic => 1.1,
        SimSeizureType.focal => 0.35,
        SimSeizureType.absence => 0.03,
        SimSeizureType.nocturnal => 0.6,
        SimSeizureType.gradual => 0.8,
        SimSeizureType.artifact => 1.2,
      };

  // ------------------------------------------------------------ helpers
  Float64List _scaled(Float64List x, double k) {
    for (var i = 0; i < x.length; i++) {
      x[i] *= k;
    }
    return x;
  }

  Float64List _blend(Float64List a, Float64List b, double w) {
    for (var i = 0; i < a.length; i++) {
      a[i] = a[i] * (1 - w) + b[i] * w;
    }
    return a;
  }

  Float64List _addSine(Float64List x, double amp, double hz) {
    final ph = _rng.nextDouble() * pi;
    for (var i = 0; i < x.length; i++) {
      x[i] += amp * sin(2 * pi * hz * i / _fs + ph);
    }
    return x;
  }

  Float64List _spikeWave(Float64List x, double amp, double hz) {
    final ph = _rng.nextDouble();
    for (var i = 0; i < x.length; i++) {
      final cycle = (i / _fs * hz + ph) % 1.0;
      final spike = cycle < 0.08 ? -amp * 1.8 * sin(pi * cycle / 0.08) : 0.0;
      final wave = cycle >= 0.08 ? amp * sin(pi * (cycle - 0.08) / 0.92) : 0.0;
      x[i] += spike + wave;
    }
    return x;
  }

  /// Electrode pops and movement drift: large but not epileptiform.
  Float64List _artifact(Float64List x, double k) {
    var drift = 0.0;
    for (var i = 0; i < x.length; i++) {
      drift += _gauss() * 0.08 * k;
      x[i] += drift;
      if (_rng.nextDouble() < 0.006 * k) {
        x[i] += (_rng.nextBool() ? 1 : -1) * 3 * k;
      }
    }
    return x;
  }

  List<double> _ecg(double hr) {
    final out = List<double>.filled(_n, 0);
    final beatHz = hr / 60.0;
    for (var i = 0; i < _n; i++) {
      _ecgPhase = (_ecgPhase + beatHz / _fs) % 1.0;
      final t = _ecgPhase;
      double g(double c, double w, double a) =>
          a * exp(-((t - c) * (t - c)) / (2 * w * w));
      out[i] =
          g(0.18, 0.025, 0.12) +
          g(0.30, 0.008, -0.15) +
          g(0.32, 0.010, 1.0) +
          g(0.34, 0.008, -0.25) +
          g(0.55, 0.040, 0.30) +
          0.02 * _gauss();
    }
    return out;
  }

  List<double> _motion(double level, SimPhase phase, SimSeizureType type) {
    final jerky =
        phase == SimPhase.ictal &&
        (type == SimSeizureType.tonicClonic ||
            type == SimSeizureType.nocturnal);
    final out = List<double>.filled(_n, 0);
    for (var i = 0; i < _n; i++) {
      final rhythm = jerky ? level * sin(2 * pi * 4.5 * i / _fs).abs() : 0.0;
      out[i] = rhythm + level * 0.5 * _gauss();
    }
    return out;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  double _gauss() {
    final u = 1 - _rng.nextDouble();
    final v = _rng.nextDouble();
    return sqrt(-2 * log(u)) * cos(2 * pi * v);
  }
}
