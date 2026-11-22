import '../enums.dart';

/// Idempotent doctor honorific formatter (`"د."` / `"Dr."`) for Point #15.
class DoctorTitleFormatter {
  DoctorTitleFormatter._();

  static final RegExp _existingTitle = RegExp(
    r'^(?:الدكتورة|الدكتور|دكتورة|دكتور|د\.|د/|dr\.?)\s*',
    caseSensitive: false,
  );

  /// Formats a doctor's display name with a single leading `"د. "` (or `"Dr. "`).
  /// Non-doctor roles are returned trimmed without modification.
  static String format(
    String rawName, {
    UserRole role = UserRole.doctor,
    bool isArabic = true,
  }) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) return isArabic ? 'د.' : 'Dr.';
    if (role != UserRole.doctor) return trimmed;

    final stripped = trimmed.replaceFirst(_existingTitle, '').trim();
    final core = stripped.isEmpty ? trimmed : stripped;
    final prefix = isArabic ? 'د. ' : 'Dr. ';
    return '$prefix$core';
  }

  /// Formats `user.name (roleName)` ensuring doctors always display `"د. <name> (<role>)"`.
  static String formatWithRole(
    String rawName,
    String roleLabel, {
    required UserRole role,
    bool isArabic = true,
  }) {
    final display = format(rawName, role: role, isArabic: isArabic);
    final label = roleLabel.trim();
    if (label.isEmpty) return display;
    return '$display ($label)';
  }
}
