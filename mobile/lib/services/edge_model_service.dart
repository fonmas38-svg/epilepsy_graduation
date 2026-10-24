import 'dart:math' as math;

import '../core/enums.dart';
import '../models/models.dart';
import 'api_client.dart';

/// Offline demonstration heuristic. This service does not execute ONNX weights.
/// Research model metrics do not measure this implementation.
class EdgeModelService {
  EdgeModelService._();
  static final EdgeModelService instance = EdgeModelService._();

  double optimalThreshold = 0.60;
  String modelArchitecture = 'Offline signal heuristic';

  Future<void> initialize() async {}

  /// Evaluates an incoming [VitalReading] using the demonstration heuristic.
  AnalyzeResult infer(VitalReading reading, {double horizonMin = 15.0}) {
    final stopwatch = Stopwatch()..start();

    // 1. Signal preprocessing & peak analysis
    final eeg = reading.eeg;
    if (eeg.length < 8 ||
        [...eeg, ...reading.ecg, ...reading.motion, reading.hr]
            .any((v) => !v.isFinite || v.abs() > 1e6) ||
        eeg.every((v) => (v - eeg.first).abs() <= 1e-8)) {
      return AnalyzeResult(
        label: RiskLabel.watch,
        confidence: 0,
        features: {
          'assessment_valid': false,
          'signal_quality': 'unusable',
          'clinically_validated': false,
          'model_executed': false,
          'offline': true,
        },
        processingMs: stopwatch.elapsedMicroseconds / 1000,
      );
    }
    var eegPeak = 0.0;
    var eegPower = 0.0;
    var zeroCrossings = 0;
    var spikeWaveCount = 0;

    if (eeg.isNotEmpty) {
      var prev = eeg.first;
      for (var i = 0; i < eeg.length; i++) {
        final val = eeg[i];
        final absVal = val.abs();
        if (absVal > eegPeak) eegPeak = absVal;
        eegPower += val * val;

        if (i > 0) {
          if ((prev >= 0 && val < 0) || (prev < 0 && val >= 0)) {
            zeroCrossings++;
          }
          // High-frequency sharp-wave / spike transient detection
          final slope = (val - prev).abs();
          if (slope > 1.8) {
            spikeWaveCount++;
          }
        }
        prev = val;
      }
      eegPower /= eeg.length;
    }

    // 2. Multimodal physiological features
    var motionEnergy = 0.0;
    if (reading.motion.isNotEmpty) {
      for (final m in reading.motion) {
        motionEnergy += m * m;
      }
      motionEnergy /= reading.motion.length;
    }

    final hr = reading.hr;

    // 3. Hand-written signal thresholds; not a neural-network forward pass.
    var convActivation = 0.0;
    if (eegPeak >= 2.0) {
      convActivation += 0.45;
    } else if (eegPeak >= 1.4) {
      convActivation += 0.28;
    } else if (eegPeak >= 0.9) {
      convActivation += 0.12;
    }

    if (spikeWaveCount >= 5) {
      convActivation += 0.25;
    } else if (spikeWaveCount >= 2) {
      convActivation += 0.12;
    }

    if (eegPower >= 1.2) {
      convActivation += 0.18;
    }

    // BiLSTM temporal risk aggregation
    var lstmScore = convActivation;
    // Autonomic response modulation: Tachycardia (HR surge) + Clonic/tonic motor bursts
    if (hr >= 115) {
      lstmScore += 0.22;
    } else if (hr >= 95) {
      lstmScore += 0.10;
    }

    if (motionEnergy >= 0.75) {
      lstmScore += 0.20;
    } else if (motionEnergy >= 0.35) {
      lstmScore += 0.08;
    }

    // Final Sigmoid Activation (Edge Seizure Probability)
    final z = 4.0 * (lstmScore - 0.45);
    final rawProb = 1.0 / (1.0 + math.exp(-z));
    final ictalProb = rawProb.clamp(0.01, 0.99);

    // Preictal rising score (forecast horizon ramp)
    final preictalScore =
        (0.55 * convActivation +
                0.30 * (hr > 85 ? (hr - 85) / 40.0 : 0.0) +
                0.15 * motionEnergy)
            .clamp(0.0, 1.0);
    // No validated time-to-onset estimator is available.

    // Classification decision using optimal ensemble threshold
    final RiskLabel label;
    final double confidence;
    if (ictalProb >= optimalThreshold ||
        (ictalProb >= 0.50 && eegPeak >= 1.6)) {
      label = RiskLabel.highRisk;
      confidence = ictalProb;
    } else if (ictalProb >= 0.32 || preictalScore >= 0.38) {
      label = RiskLabel.watch;
      confidence = math.max(ictalProb, preictalScore);
    } else {
      label = RiskLabel.stable;
      confidence = 1.0 - ictalProb;
    }

    stopwatch.stop();
    final elapsedMs = math.max(0.5, stopwatch.elapsedMicroseconds / 1000.0);

    return AnalyzeResult(
      label: label,
      confidence: double.parse(confidence.clamp(0.50, 0.99).toStringAsFixed(4)),
      features: {
        'edge_model': modelArchitecture,
        'model_executed': false,
        'clinically_validated': false,
        'offline': true,
        'ictal_prob': double.parse(ictalProb.toStringAsFixed(4)),
        'preictal_prob': double.parse(preictalScore.toStringAsFixed(4)),
        'lead_time_min': null,
        'horizon_min': horizonMin,
        'predicted': preictalScore >= 0.60,
        'prediction_source': 'simulated_heuristic',
        'eeg_peak': double.parse(eegPeak.toStringAsFixed(2)),
        'eeg_power': double.parse(eegPower.toStringAsFixed(2)),
        'motion_energy': double.parse(motionEnergy.toStringAsFixed(2)),
        'hr_mean': hr,
        'spike_wave_count': spikeWaveCount,
        'zero_crossings': zeroCrossings,
        'optimal_threshold': optimalThreshold,
      },
      processingMs: elapsedMs,
    );
  }
}
