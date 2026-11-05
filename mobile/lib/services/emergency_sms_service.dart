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

  Future<SmsOutcome> composeEmergencySms({
    required List<String> phoneNumbers,
    required String patientName,
    GpsFix? fix,
    String? eventId,
    DateTime? occurredAt,
  }) async {
    final recipients = normalizeRecipients(phoneNumbers);
    if (recipients.isEmpty) return SmsOutcome.noRecipients;
    final location = fix != null && fix.valid
        ? 'الإحداثيات: $fix. الموقع: ${fix.mapsUrl}${fix.accuracy == null ? '' : '. دقة تقريبية: ${fix.accuracy!.round()} متر'}'
        : 'تعذر الحصول على موقع حديث؛ لا توجد إحداثيات مؤكدة.';
    final text =
        'طلب مساعدة — المريض ($patientName). الوقت: ${(occurredAt ?? DateTime.now()).toUtc().toIso8601String()}. $location${eventId == null ? '' : ' مرجع الحدث: $eventId'}';
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
