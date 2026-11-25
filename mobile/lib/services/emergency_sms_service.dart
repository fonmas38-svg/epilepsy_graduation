import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'location_service.dart';

enum SmsOutcome { composerOpened, noRecipients, unsupported, failed }

typedef SmsLauncher = Future<bool> Function(Uri uri);

/// Opening a composer requires user confirmation and proves no delivery.
class EmergencySmsService {
  const EmergencySmsService({SmsLauncher? canOpen, SmsLauncher? open})
    : _canOpen = canOpen,
      _open = open;
  final SmsLauncher? _canOpen;
  final SmsLauncher? _open;

  static List<String> normalizeRecipients(List<String> numbers) => numbers
      .map((p) => p.trim().replaceAll(RegExp(r'[\s()\-]'), ''))
      .where((p) => RegExp(r'^\+?[0-9]{7,15}$').hasMatch(p))
      .toSet()
      .toList();

  /// Phone-local date and 12-hour time, e.g. `2026/11/25 3:07 م`.
  /// Caregivers read this on their own phone; UTC ISO strings confused them.
  static String formatLocal12h(DateTime at) {
    final t = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final period = t.hour < 12 ? 'ص' : 'م';
    return '${t.year}/${two(t.month)}/${two(t.day)} $hour:${two(t.minute)} $period';
  }

  Future<SmsOutcome> composeEmergencySms({
    required List<String> phoneNumbers,
    required String patientName,
    GpsFix? fix,
    String? eventId,
    DateTime? occurredAt,
  }) async {
    final recipients = normalizeRecipients(phoneNumbers);
    if (recipients.isEmpty) return SmsOutcome.noRecipients;
    final quality = fix?.describe(arabic: true) ?? '';
    final location = fix != null && fix.valid
        ? 'الإحداثيات: $fix. الموقع: ${fix.mapsUrl}${quality.isEmpty ? '' : '. $quality'}'
        : 'تعذر الحصول على موقع حديث؛ لا توجد إحداثيات مؤكدة.';
    final text =
        'طلب مساعدة — المريض ($patientName). الوقت: ${formatLocal12h(occurredAt ?? DateTime.now())}. $location${eventId == null ? '' : ' مرجع الحدث: $eventId'}';
    final separator = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? '&'
        : '?';
    final uri = Uri.parse(
      'sms:${recipients.join(',')}${separator}body=${Uri.encodeComponent(text)}',
    );
    try {
      if (!await (_canOpen ?? canLaunchUrl)(uri)) return SmsOutcome.unsupported;
      final launched = await (_open ?? (Uri value) => launchUrl(value))(uri);
      return launched ? SmsOutcome.composerOpened : SmsOutcome.failed;
    } catch (_) {
      return SmsOutcome.failed;
    }
  }

  Future<bool> sendEmergencySms({
    required List<String> phoneNumbers,
    required String patientName,
    GpsFix? fix,
  }) async =>
      await composeEmergencySms(
        phoneNumbers: phoneNumbers,
        patientName: patientName,
        fix: fix,
      ) ==
      SmsOutcome.composerOpened;
}
