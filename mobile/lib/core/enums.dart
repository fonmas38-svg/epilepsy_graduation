enum UserRole { patient, caregiver, doctor }

extension UserRoleX on UserRole {
  String get value => name;

  static UserRole fromString(String raw) {
    return UserRole.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => UserRole.patient,
    );
  }

  String get labelAr => switch (this) {
        UserRole.patient => 'مريض',
        UserRole.caregiver => 'أحد أفراد الأسرة',
        UserRole.doctor => 'طبيب',
      };
}

enum RiskLabel { stable, watch, highRisk }

extension RiskLabelX on RiskLabel {
  String get apiValue => switch (this) {
        RiskLabel.stable => 'stable',
        RiskLabel.watch => 'watch',
        RiskLabel.highRisk => 'high_risk',
      };

  String get labelAr => switch (this) {
        RiskLabel.stable => 'مستقر',
        RiskLabel.watch => 'يحتاج مراقبة',
        RiskLabel.highRisk => 'خطر مرتفع',
      };

  static RiskLabel fromApi(String raw) {
    return switch (raw) {
      'watch' => RiskLabel.watch,
      'high_risk' => RiskLabel.highRisk,
      _ => RiskLabel.stable,
    };
  }
}
