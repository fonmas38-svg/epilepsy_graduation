import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../core/enums.dart';

/// Persists user-configurable settings.
///
/// Originally this held only the seizure-prediction horizon (SPH, #21). It now
/// also carries the preferences `docs/frontend-plan-ar.md` §2.4/§3.6 require:
/// theme mode (dark mode is mandatory, and the choice has to survive a restart),
/// language, alert sensitivity, quiet hours, and who gets notified at which
/// level.
///
/// Two properties are kept from the original design on purpose:
///
/// * **Best-effort persistence.** Every write is wrapped; if the platform store
///   is unavailable the in-memory value still updates. Nothing on the prediction
///   or alerting path may hard-fail because a preference could not be saved.
/// * **Clamped values.** A corrupt stored value can never push the app outside
///   the documented range.
///
/// It is a [ChangeNotifier] so that changing the theme or language rebuilds the
/// app immediately; `AppState` forwards these notifications.
class SettingsService extends ChangeNotifier {
  static const _horizonKey = 'preictal_horizon_min';
  static const _themeKey = 'theme_mode';
  static const _localeKey = 'locale_code';
  static const _sensitivityKey = 'alert_sensitivity';
  static const _quietEnabledKey = 'quiet_hours_enabled';
  static const _quietStartKey = 'quiet_hours_start_min';
  static const _quietEndKey = 'quiet_hours_end_min';
  static const _notifyCautionKey = 'notify_family_on_caution';
  static const _shareLocationKey = 'share_location_on_alert';
  static const _autoLockEnabledKey = 'auto_lock_enabled';
  static const _autoLockMinutesKey = 'auto_lock_minutes';

  double _horizonMin = AppConfig.defaultHorizonMin;
  ThemeMode _themeMode = ThemeMode.system;
  String? _localeCode;
  AlertSensitivity _sensitivity = AlertSensitivity.medium;
  bool _quietHoursEnabled = false;
  int _quietStartMinutes = 22 * 60;
  int _quietEndMinutes = 7 * 60;
  bool _notifyFamilyOnCaution = false;
  bool _shareLocationOnAlert = true;
  bool _autoLockEnabled = true;
  int _autoLockMinutes = 5;

  /// The currently-loaded horizon (minutes). Read synchronously after [load];
  /// clamped to the spec range.
  double get horizonMin => _horizonMin;

  ThemeMode get themeMode => _themeMode;

  /// `null` means «follow the device language».
  String? get localeCode => _localeCode;

  /// `null` when following the system locale, otherwise the chosen locale.
  Locale? get locale => _localeCode == null ? null : Locale(_localeCode!);

  AlertSensitivity get sensitivity => _sensitivity;

  bool get quietHoursEnabled => _quietHoursEnabled;
  int get quietStartMinutes => _quietStartMinutes;
  int get quietEndMinutes => _quietEndMinutes;
  TimeOfDay get quietStart => TimeOfDay(
    hour: _quietStartMinutes ~/ 60,
    minute: _quietStartMinutes % 60,
  );
  TimeOfDay get quietEnd =>
      TimeOfDay(hour: _quietEndMinutes ~/ 60, minute: _quietEndMinutes % 60);

  bool get notifyFamilyOnCaution => _notifyFamilyOnCaution;
  bool get shareLocationOnAlert => _shareLocationOnAlert;
  bool get autoLockEnabled => _autoLockEnabled;
  int get autoLockMinutes => _autoLockMinutes;
  Duration get autoLockTimeout => Duration(minutes: _autoLockMinutes);

  /// Load persisted settings once at startup. Any failure leaves the defaults.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getDouble(_horizonKey);
      if (v != null) _horizonMin = _clampHorizon(v);

      _themeMode = switch (prefs.getString(_themeKey)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

      final code = prefs.getString(_localeKey);
      _localeCode = (code == 'ar' || code == 'en') ? code : null;

      _sensitivity = AlertSensitivity.fromString(
        prefs.getString(_sensitivityKey),
      );

      _quietHoursEnabled = prefs.getBool(_quietEnabledKey) ?? false;
      _quietStartMinutes = _clampMinutes(
        prefs.getInt(_quietStartKey) ?? _quietStartMinutes,
      );
      _quietEndMinutes = _clampMinutes(
        prefs.getInt(_quietEndKey) ?? _quietEndMinutes,
      );
      _notifyFamilyOnCaution = prefs.getBool(_notifyCautionKey) ?? false;
      _shareLocationOnAlert = prefs.getBool(_shareLocationKey) ?? true;
      _autoLockEnabled = prefs.getBool(_autoLockEnabledKey) ?? true;
      final lockM = prefs.getInt(_autoLockMinutesKey);
      if (lockM != null) {
        _autoLockMinutes = _clampAutoLockMinutes(lockM);
      }
    } catch (_) {
      // keep defaults
    }
    notifyListeners();
  }

  /// Persist a new horizon (clamped to the spec range) and return the stored
  /// value. The in-memory value updates even if persistence fails.
  Future<double> setHorizonMin(double minutes) async {
    _horizonMin = _clampHorizon(minutes);
    await _write((p) => p.setDouble(_horizonKey, _horizonMin));
    return _horizonMin;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _write((p) => p.setString(_themeKey, mode.name));
  }

  /// Pass `null` to follow the device language.
  Future<void> setLocaleCode(String? code) async {
    _localeCode = (code == 'ar' || code == 'en') ? code : null;
    await _write(
      (p) => _localeCode == null
          ? p.remove(_localeKey)
          : p.setString(_localeKey, _localeCode!),
    );
  }

  Future<void> setSensitivity(AlertSensitivity value) async {
    _sensitivity = value;
    await _write((p) => p.setString(_sensitivityKey, value.name));
  }

  Future<void> setQuietHoursEnabled(bool value) async {
    _quietHoursEnabled = value;
    await _write((p) => p.setBool(_quietEnabledKey, value));
  }

  Future<void> setQuietWindow(TimeOfDay start, TimeOfDay end) async {
    _quietStartMinutes = _clampMinutes(start.hour * 60 + start.minute);
    _quietEndMinutes = _clampMinutes(end.hour * 60 + end.minute);
    await _write((p) async {
      await p.setInt(_quietStartKey, _quietStartMinutes);
      await p.setInt(_quietEndKey, _quietEndMinutes);
    });
  }

  Future<void> setNotifyFamilyOnCaution(bool value) async {
    _notifyFamilyOnCaution = value;
    await _write((p) => p.setBool(_notifyCautionKey, value));
  }

  Future<void> setShareLocationOnAlert(bool value) async {
    _shareLocationOnAlert = value;
    await _write((p) => p.setBool(_shareLocationKey, value));
  }

  Future<void> setAutoLockEnabled(bool value) async {
    _autoLockEnabled = value;
    await _write((p) => p.setBool(_autoLockEnabledKey, value));
  }

  Future<void> setAutoLockMinutes(int minutes) async {
    _autoLockMinutes = _clampAutoLockMinutes(minutes);
    await _write((p) => p.setInt(_autoLockMinutesKey, _autoLockMinutes));
  }

  int _clampAutoLockMinutes(int v) {
    if ([5, 10, 15, 30].contains(v)) return v;
    return 5;
  }

  /// True when [at] falls inside the quiet window, wrap-around handled (22:00 →
  /// 07:00 is one window that crosses midnight, not an empty one).
  bool isQuietAt(DateTime at) {
    if (!_quietHoursEnabled) return false;
    final m = at.hour * 60 + at.minute;
    if (_quietStartMinutes == _quietEndMinutes) return false;
    return _quietStartMinutes < _quietEndMinutes
        ? m >= _quietStartMinutes && m < _quietEndMinutes
        : m >= _quietStartMinutes || m < _quietEndMinutes;
  }

  /// Whether a notification at [label] may be muted right now.
  ///
  /// **High risk always overrides quiet hours** (§3.6). This is not a preference
  /// the patient can turn off, and it is checked here rather than at each call
  /// site so no future screen can accidentally make it optional.
  bool mayMute(RiskLabel label, {DateTime? now}) {
    if (label == RiskLabel.highRisk) return false;
    return isQuietAt(now ?? DateTime.now());
  }

  /// Whether family members should be notified at [label].
  ///
  /// `highRisk` is unconditional for the same reason as [mayMute].
  bool notifiesFamily(RiskLabel label) => switch (label) {
    RiskLabel.highRisk => true,
    RiskLabel.watch => _notifyFamilyOnCaution,
    RiskLabel.stable => false,
  };

  Future<void> _write(Future<void> Function(SharedPreferences p) body) async {
    notifyListeners();
    try {
      await body(await SharedPreferences.getInstance());
    } catch (_) {
      // in-memory value still updated
    }
  }

  double _clampHorizon(double v) =>
      v.clamp(AppConfig.minHorizonMin, AppConfig.maxHorizonMin).toDouble();

  int _clampMinutes(int v) => v.clamp(0, 24 * 60 - 1);
}
