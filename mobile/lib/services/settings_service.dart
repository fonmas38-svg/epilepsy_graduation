import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';

/// Persists user-configurable prediction settings (#21). Currently the
/// seizure-prediction horizon (SPH) — configurable 5–30 min per the spec —
/// stored in `shared_preferences`. Fully additive and best-effort: if the
/// platform store is unavailable the in-memory default is used so nothing on
/// the prediction path can hard-fail. The stored value always stays within
/// [AppConfig.minHorizonMin]..[AppConfig.maxHorizonMin].
class SettingsService {
  static const _horizonKey = 'preictal_horizon_min';

  double _horizonMin = AppConfig.defaultHorizonMin;

  /// The currently-loaded horizon (minutes). Read synchronously after [load];
  /// clamped to the spec range.
  double get horizonMin => _horizonMin;

  /// Load persisted settings once at startup. Any failure leaves the default.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getDouble(_horizonKey);
      if (v != null) _horizonMin = _clamp(v);
    } catch (_) {
      // keep default
    }
  }

  /// Persist a new horizon (clamped to the spec range) and return the stored
  /// value. The in-memory value updates even if persistence fails.
  Future<double> setHorizonMin(double minutes) async {
    _horizonMin = _clamp(minutes);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_horizonKey, _horizonMin);
    } catch (_) {
      // in-memory value still updated
    }
    return _horizonMin;
  }

  double _clamp(double v) =>
      v.clamp(AppConfig.minHorizonMin, AppConfig.maxHorizonMin).toDouble();
}
