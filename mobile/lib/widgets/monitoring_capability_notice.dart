import 'package:flutter/material.dart';
import '../core/theme/risk_view.dart';
import '../core/ui/common.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_state.dart';
import '../services/emergency_sms_service.dart';
import '../services/location_service.dart';
import '../services/monitoring_service.dart';

/// Surface actual capabilities even when no forecast could be produced.
class MonitoringCapabilityNotice extends StatelessWidget {
  const MonitoringCapabilityNotice({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final ar = AppLocalizations.of(context).isArabic;
    final missingStream =
        app.monitoring.source == SignalSource.headDevice &&
        !app.monitoring.deviceConnected;
    final location = app.location.lastResult?.status;
    final messages = <String>[
      ar
          ? 'النموذج العصبي المحلي غير مفعّل على هذا الإصدار. عند تعذر السحابة تستخدم المحاكاة قواعد تجريبية محدودة؛ لا توفر نفس أداء النموذج السحابي. تحقق من الاتصال والجهاز، ولا تعتمد على غياب التنبيه كدليل سلامة.'
          : 'This build has no active local neural model. Simulation uses limited experimental rules when cloud analysis fails; it does not provide cloud model parity. Check the connection and device. No alert does not establish safety.',
      if (missingStream)
        ar
            ? 'لا تصل عينات حديثة من الجهاز. لا توجد وصلة EEG محلية مباشرة في هذا الإصدار؛ المراقبة المستمرة غير متاحة حتى عودة مصدر العينات.'
            : 'No fresh device samples. This build has no direct local EEG connection; continuous monitoring is unavailable until the sample source returns.',
      if (location != null && location != LocationStatus.available)
        locationMessage(location, ar),
      if (app.lastSmsOutcome != null) smsMessage(app.lastSmsOutcome!, ar),
    ];
    return InfoNote(
      text: messages.join('\n\n'),
      icon: Icons.info_outline,
      view: RiskView.caution,
    );
  }

  static String locationMessage(
    LocationStatus status,
    bool ar,
  ) => switch (status) {
    LocationStatus.serviceDisabled =>
      ar
          ? 'خدمة الموقع مغلقة. فعّل الموقع في إعدادات الهاتف ثم حاول مجددًا.'
          : 'Location services are disabled. Enable location in phone settings and retry.',
    LocationStatus.permissionDenied =>
      ar
          ? 'إذن الموقع غير ممنوح. اسمح بالوصول للحصول على إحداثيات الطوارئ.'
          : 'Location permission is denied. Allow access for emergency coordinates.',
    LocationStatus.permissionDeniedForever =>
      ar
          ? 'إذن الموقع محظور من الإعدادات. افتح إعدادات التطبيق وفعّل الإذن.'
          : 'Location permission is blocked. Enable it in app settings.',
    LocationStatus.timedOut =>
      ar
          ? 'لم تصل إشارة موقع في المهلة. انتقل لمكان مكشوف إن أمكن وحاول مجددًا؛ قد يعمل GPS دون إنترنت.'
          : 'Location timed out. Try a clear view of the sky if possible and retry; GPS may work without internet.',
    LocationStatus.unsupported =>
      ar
          ? 'خدمة الموقع غير مدعومة أو غير متاحة لهذا الإصدار على جهازك. لا توجد إحداثيات مؤكدة.'
          : 'Location is unsupported or unavailable on this build/device. No confirmed coordinates.',
    LocationStatus.stale =>
      ar
          ? 'الموقع المتاح قديم؛ لم يُرسل على أنه موقعك الحالي.'
          : 'The available fix is stale and was not sent as your current location.',
    _ =>
      ar
          ? 'تعذر الحصول على موقع صالح. هذا لا يثبت غياب مستقبل GPS؛ تحقق من الخدمة والإذن والإشارة.'
          : 'No valid location fix. This does not establish missing GPS hardware; check services, permission and reception.',
  };

  static String smsMessage(SmsOutcome status, bool ar) => switch (status) {
    SmsOutcome.composerOpened =>
      ar
          ? 'فُتح محرر SMS. يجب تأكيد الإرسال يدويًا؛ لم يؤكد التطبيق الإرسال أو الوصول. يلزم توفر خدمة الرسائل لدى المشغل.'
          : 'SMS composer opened. Confirm sending manually; sending and delivery are unverified. Carrier SMS service is required.',
    SmsOutcome.noRecipients =>
      ar
          ? 'تعذر تجهيز SMS لعدم وجود أرقام طوارئ صالحة. أضف أرقام المرافقين إلى جهات الطوارئ.'
          : 'No valid emergency phone numbers. Add caregiver numbers to emergency contacts.',
    SmsOutcome.unsupported =>
      ar
          ? 'لا يوجد تطبيق رسائل متاح. استخدم هاتفًا يدعم SMS أو اتصل بجهة الطوارئ مباشرة.'
          : 'No SMS app is available. Use an SMS-capable phone or call your emergency contact directly.',
    SmsOutcome.failed =>
      ar
          ? 'تعذر فتح محرر SMS؛ لم تُرسل الرسالة عبر التطبيق. اتصل بجهة الطوارئ مباشرة.'
          : 'SMS composer could not open; the app did not send a message. Call your emergency contact directly.',
  };
}
