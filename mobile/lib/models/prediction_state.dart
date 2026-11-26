import '../core/enums.dart';

/// Forecasting layer that rides ALONGSIDE the detection [RiskAssessment].
///
/// This expresses seizure *prediction* — the probability the patient is in a
/// preictal state and an estimated lead-time (minutes) until a possible
/// seizure — as a separate, additive concern. It never replaces the
/// `stable / watch / high_risk` detection label; it augments it. All fields
/// are nullable-friendly so the app degrades cleanly to detection-only when the
/// backend (or an older build) sends no forecast.
class PredictionState {
  const PredictionState({
    required this.preictalProb,
    this.leadTimeMin,
    this.horizonMin,
    this.predicted = false,
    this.source,
    this.trajectory = const [],
    this.drivers,
  });

  /// P(preictal) in [0,1] — rises as a seizure approaches.
  final double preictalProb;

  /// Estimated minutes until possible onset (counts down as [preictalProb] rises).
  final double? leadTimeMin;

  /// Seizure-prediction-horizon used for this forecast (minutes).
  final double? horizonMin;

  /// True once the pre-alert threshold has been crossed.
  final bool predicted;

  /// `"simulated_heuristic"` (live demo) | `"cnn_lstm_preictal"` (real model).
  final String? source;

  /// Recent history of preictal probabilities (oldest→newest) for a sparkline.
  final List<double> trajectory;

  /// Auditable "why": per-channel contributions (eeg/hr/motion/ecg) in [0,1].
  final Map<String, double>? drivers;

  /// Whether the forecast came from the real trained model vs. the heuristic.
  bool get isModel =>
      source == 'cnn_lstm_preictal' || source == 'cloud_preictal_net';

  bool get hasLeadTime => leadTimeMin != null;

  /// Map the forecast probability onto the shared risk palette so the gauge
  /// reuses one colour system with [StatusBadge]. This is a *visual* banding of
  /// the forecast, NOT a detection label.
  RiskLabel get band {
    if (preictalProb >= 0.6) return RiskLabel.highRisk;
    if (preictalProb >= 0.3) return RiskLabel.watch;
    return RiskLabel.stable;
  }

  static double? _d(dynamic v) => v is num && v.isFinite ? v.toDouble() : null;

  /// Build from a merged `features` / assessment / device-status map (snake_case
  /// keys straight from the backend). Returns `null` when no `preictal_prob` is
  /// present so callers can fall back to detection-only rendering.
  static PredictionState? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final prob = _d(map['preictal_prob']);
    if (prob == null) return null;

    Map<String, double>? drivers;
    final comp = map['components'];
    if (comp is Map) {
      final raw = comp['preictal_drivers'];
      if (raw is Map) {
        drivers = raw.map((k, v) => MapEntry(k.toString(), _d(v) ?? 0.0));
      }
    }
    // Some payloads carry the drivers at the top level already.
    if (drivers == null && map['preictal_drivers'] is Map) {
      drivers = (map['preictal_drivers'] as Map).map(
        (k, v) => MapEntry(k.toString(), _d(v) ?? 0.0),
      );
    }

    final rawTraj = map['preictal_trajectory'];
    final clamped = prob.clamp(0.0, 1.0).toDouble();
    return PredictionState(
      preictalProb: clamped,
      // Legacy score-derived lead times are not time-to-onset estimates.
      leadTimeMin: null,
      horizonMin: _d(map['horizon_min']),
      predicted: map['predicted'] == true,
      source: map['prediction_source'] as String?,
      trajectory: rawTraj is List
          ? rawTraj
                .map(_d)
                .whereType<double>()
                .map((e) => e.clamp(0.0, 1.0).toDouble())
                .toList()
          : const [],
      drivers: drivers,
    );
  }

  Map<String, dynamic> toMap() => {
    'preictal_prob': preictalProb,
    'lead_time_min': leadTimeMin,
    'horizon_min': horizonMin,
    'predicted': predicted,
    'prediction_source': source,
    'preictal_trajectory': trajectory,
    if (drivers != null) 'preictal_drivers': drivers,
  };

  PredictionState copyWith({List<double>? trajectory}) => PredictionState(
    preictalProb: preictalProb,
    leadTimeMin: leadTimeMin,
    horizonMin: horizonMin,
    predicted: predicted,
    source: source,
    trajectory: trajectory ?? this.trajectory,
    drivers: drivers,
  );
}
