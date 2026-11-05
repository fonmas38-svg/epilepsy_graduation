import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

class AppConfig {
  static const cloudProductionUrl = 'https://epilepsy-graduation.onrender.com';
  static const localAndroidUrl = 'http://10.0.2.2:8000';
  static const localDesktopUrl = 'http://127.0.0.1:8000';

  /// Default local URL adapted automatically to the running platform:
  /// Android Emulator accesses host localhost via 10.0.2.2; Windows/Web uses 127.0.0.1.
  static String get defaultLocalUrl {
    if (kIsWeb) return localDesktopUrl;
    try {
      if (Platform.isAndroid) return localAndroidUrl;
    } catch (_) {}
    return localDesktopUrl;
  }

  /// Base URL of the analysis backend. Defaults to the live cloud backend.
  /// Can be overridden via environment or updated dynamically at runtime in AppState.
  static String get apiBaseUrl {
    const override = String.fromEnvironment('API_BASE_URL');
    if (override.isNotEmpty) return override;
    return demoMode ? defaultLocalUrl : cloudProductionUrl;
  }

  /// Demo mode must be explicitly enabled and never targets the live API by default.
  static const demoMode = bool.fromEnvironment('DEMO_MODE', defaultValue: false);

  static const simulationInterval = Duration(minutes: 5);

  static const devicePollInterval = Duration(seconds: 3);
  static const localRetention = Duration(hours: 24);
  static const deviceDemoToken = 'headband-demo-token';

  /// Seizure-prediction horizon (SPH) default and bounds, in minutes. The
  /// horizon is user-configurable per the spec (5–30 min, #21): the offline
  /// forecast heuristic and the prediction UI read the persisted value, while
  /// the backend and simulator take it server-side via PREICTAL_HORIZON_MIN /
  /// --horizon-min. Default matches the backend's PREICTAL_HORIZON_MIN default.
  static const defaultHorizonMin = 15.0;
  static const minHorizonMin = 5.0;
  static const maxHorizonMin = 30.0;

  /// Per-role enrollment secrets exchanged for a signed JWT at POST /auth/token.
  /// These mirror the backend defaults (app/routers/auth.py). In a real
  /// deployment inject them per build with --dart-define and never commit real
  /// secrets — here they are demo credentials for the graduation MVP.
  static const enrollDeviceSecret = String.fromEnvironment(
    'ENROLL_DEVICE_SECRET',
    defaultValue: 'enroll-device-demo',
  );
  static const enrollPatientSecret = String.fromEnvironment(
    'ENROLL_PATIENT_SECRET',
    defaultValue: 'enroll-patient-demo',
  );
  static const enrollCaregiverSecret = String.fromEnvironment(
    'ENROLL_CAREGIVER_SECRET',
    defaultValue: 'enroll-caregiver-demo',
  );
  static const enrollDoctorSecret = String.fromEnvironment(
    'ENROLL_DOCTOR_SECRET',
    defaultValue: 'enroll-doctor-demo',
  );

  /// Refresh the JWT this long before its `exp` so requests never race expiry.
  static const tokenRefreshLeeway = Duration(seconds: 30);
}
