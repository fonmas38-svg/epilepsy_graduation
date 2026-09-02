import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'location_service.dart';

/// Emergency SMS Fallback Service.
///
/// Ensures patient safety when internet connectivity (Wi-Fi / Mobile Data) is down.
/// Composes an urgent SMS carrying GPS coordinates and Google Maps link,
/// and dispatches it directly to the patient's registered emergency contacts.
class EmergencySmsService {
  const EmergencySmsService();

  /// Build and trigger emergency SMS fallback.
  Future<bool> sendEmergencySms({
    required List<String> phoneNumbers,
    required String patientName,
    GpsFix? fix,
  }) async {
    if (phoneNumbers.isEmpty) {
      debugPrint('EmergencySmsService: No emergency contact phone numbers provided.');
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
      queryParameters: <String, String>{
        'body': message,
      },
    );

    try {
      if (await canLaunchUrl(smsUri)) {
        await launchUrl(smsUri);
        return true;
      } else {
        // Fallback: try launching with simple query string
        final directUri = Uri.parse('sms:$recipients?body=${Uri.encodeComponent(message)}');
        if (await canLaunchUrl(directUri)) {
          await launchUrl(directUri);
          return true;
        }
      }
    } catch (e) {
      debugPrint('EmergencySmsService failed to dispatch SMS: $e');
    }
    return false;
  }
}
