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
/// The numbers come from the operating points documented in §5.3 of the plan.
/// [preictalThreshold] is the probability at which a pre-alert fires; the rest
/// are the clinically meaningful consequences, kept beside it so no screen can
/// show a sensitivity without being able to state its cost.
enum AlertSensitivity {
  low(preictalThreshold: 0.72, detection: 0.71, falseAlarmsPerHour: 0.18),
  medium(preictalThreshold: 0.60, detection: 0.84, falseAlarmsPerHour: 0.45),
  high(preictalThreshold: 0.45, detection: 0.92, falseAlarmsPerHour: 1.10);

  const AlertSensitivity({
    required this.preictalThreshold,
    required this.detection,
    required this.falseAlarmsPerHour,
  });

  /// Pre-alert fires at or above this preictal probability.
  final double preictalThreshold;

  /// Share of real seizures caught, from the offline evaluation.
  final double detection;

  /// Expected false alarms per hour at this operating point.
  final double falseAlarmsPerHour;

  /// Roughly «one false alarm every N hours» — the form §5.3 asks for, because
  /// «0.45/hour» does not tell a doctor what their patient's day looks like.
  double get hoursBetweenFalseAlarms =>
      falseAlarmsPerHour <= 0 ? double.infinity : 1 / falseAlarmsPerHour;

  String get value => name;

  static AlertSensitivity fromString(String? raw) =>
      AlertSensitivity.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => AlertSensitivity.medium,
      );
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

  static ServerMode fromString(String? raw) =>
      ServerMode.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => ServerMode.auto,
      );
}

