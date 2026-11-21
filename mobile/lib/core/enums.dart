enum UserRole { patient, caregiver, doctor, admin }

extension UserRoleX on UserRole {
  String get value => name;

  static UserRole fromString(String raw) {
    return UserRole.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => UserRole.patient,
    );
  }
}

enum RiskLabel { stable, watch, highRisk }

extension RiskLabelX on RiskLabel {
  String get apiValue => switch (this) {
    RiskLabel.stable => 'stable',
    RiskLabel.watch => 'watch',
    RiskLabel.highRisk => 'high_risk',
  };

  static RiskLabel fromApi(String raw) {
    return switch (raw) {
      'watch' => RiskLabel.watch,
      'high_risk' => RiskLabel.highRisk,
      _ => RiskLabel.stable,
    };
  }
}

/// How eagerly this patient wants to be pre-alerted — `docs/frontend-plan-ar.md`
/// §3.6 and §5.3, expressed once so the patient's own «حساسية التنبيه» slider
/// and the doctor's «نقاط التشغيل» table refer to the same three settings rather
/// than to two independent scales.
///
/// Legacy local configuration values, not a clinical performance evaluation.
/// Patient-specific engine configuration requires a separate server contract.
enum AlertSensitivity {
  low(preictalThreshold: 0.72),
  medium(preictalThreshold: 0.60),
  high(preictalThreshold: 0.45);

  const AlertSensitivity({required this.preictalThreshold});

  /// Pre-alert fires at or above this preictal probability.
  final double preictalThreshold;

  String get value => name;

  static AlertSensitivity fromString(String? raw) => AlertSensitivity.values
      .firstWhere((e) => e.name == raw, orElse: () => AlertSensitivity.medium);
}

enum ServerMode { auto, cloud, local, custom }

extension ServerModeX on ServerMode {
  String get value => name;

  String get arabicLabel => switch (this) {
    ServerMode.auto => 'تلقائي ذكي (سحابي ⇆ محلي)',
    ServerMode.cloud => 'سحابي (Render Cloud)',
    ServerMode.local => 'محلي (Localhost)',
    ServerMode.custom => 'عنوان مخصص (Custom IP)',
  };

  static ServerMode fromString(String? raw) => ServerMode.values.firstWhere(
    (e) => e.name == raw,
    orElse: () => ServerMode.auto,
  );
}
