import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'location_service.dart';

/// Emergency SMS Fallback Service.
///
/// Opens the SMS composer with emergency contacts and optional GPS coordinates.
/// The user must confirm sending. A successful launch is not a delivery receipt.
class EmergencySmsService {
  const EmergencySmsService();

  /// Build and trigger emergency SMS fallback.
  Future<bool> sendEmergencySms({
    required List<String> phoneNumbers,
    required String patientName,
    GpsFix? fix,
  }) async {
    if (phoneNumbers.isEmpty) {
      debugPrint(
        'EmergencySmsService: No emergency contact phone numbers provided.',
      );
      return false;
    }

    final locationText = fix != null
        ? 'الموقع: ${fix.mapsUrl}'
        : 'الموقع: تعذر تحديد إحداثيات GPS بدقة.';

    final message =
        'استغاثة عاجلة — نظام مراقبة الصرع: المريض ($patientName) بحاجة لمساعدة فورية. $locationText';

    // Format phone numbers for SMS URI (comma-separated on Android/iOS)
    final recipients = phoneNumbers.where((p) => p.trim().isNotEmpty).join(',');
    if (recipients.isEmpty) return false;

    final smsUri = Uri(
      scheme: 'sms',
      path: recipients,
      query: 'body=${Uri.encodeComponent(message)}',
    );

    try {
      if (await canLaunchUrl(smsUri)) {
        return await launchUrl(smsUri);
      } else {
        // Fallback: try launching with simple query string
        final directUri = Uri.parse(
          'sms:$recipients?body=${Uri.encodeComponent(message)}',
        );
        if (await canLaunchUrl(directUri)) {
          return await launchUrl(directUri);
        }
      }
    } catch (e) {
      debugPrint('EmergencySmsService failed to dispatch SMS: $e');
    }
    return false;
  }
}
