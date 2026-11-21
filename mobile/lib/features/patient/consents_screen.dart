import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/router/route_names.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';
import '../../models/care_models.dart';
import '../../providers/app_state.dart';

/// Localised name of a consent tier.
String consentLevelLabel(ConsentLevel level, AppLocalizations l) =>
    switch (level) {
      ConsentLevel.alertsOnly => l.consentAlertsOnly,
      ConsentLevel.basic => l.consentBasic,
      ConsentLevel.full => l.consentFull,
      ConsentLevel.guardian => l.consentGuardian,
    };

/// What the tier actually grants, in plain language — the part that makes the
/// consent informed rather than nominal.
String consentLevelDesc(ConsentLevel level, AppLocalizations l) =>
    switch (level) {
      ConsentLevel.alertsOnly => l.consentAlertsOnlyDesc,
      ConsentLevel.basic => l.consentBasicDesc,
      ConsentLevel.full => l.consentFullDesc,
      ConsentLevel.guardian => l.consentGuardianDesc,
    };

class ConsentsScreen extends StatelessWidget {
  const ConsentsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final ar = AppLocalizations.of(context).isArabic;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F9FD),
      appBar: AppBar(
        title: Text(
          ar ? 'المشاركة والصلاحيات' : 'Sharing and permissions',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF0D253C),
            fontSize: 19,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF0D253C)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE4EDF7), height: 1),
        ),
      ),
      body: ResponsiveContent(
        maxWidth: 860,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE4EDF7), width: 1.2),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x06000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.people_outline_rounded,
                          color: Color(0xFF0066FF),
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          ar
                              ? 'التحكم في وصول المرافقين'
                              : 'Manage caregiver access',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0D253C),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    ar
                        ? 'يمكنك تفعيل وصول المرافق إلى بياناتك أو إيقافه من صفحة المرافقين. يطبق الخادم صلاحيات العلاقات الفعالة؛ القناة الخاصة بين المريض والطبيب لا تُعرض للمرافق.'
                        : 'Enable or disable access from the caregivers page. The server enforces active care relationships; the private patient–doctor channel is not shared with caregivers.',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0066FF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      onPressed: () => Navigator.pushNamed(
                        context,
                        Routes.patientCaregivers,
                      ),
                      icon: const Icon(Icons.people_rounded, size: 20),
                      label: Text(
                        ar ? 'إدارة المرافقين' : 'Manage caregivers',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE4EDF7), width: 1.2),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x06000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.shield_outlined,
                          color: Color(0xFFD97706),
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          ar
                              ? 'مستويات المشاركة التفصيلية'
                              : 'Detailed sharing levels',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0D253C),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    ar
                        ? 'اختيار مستوى مثل «تنبيهات فقط» أو إخفاء الموقع عن مرافق محدد غير مدعوم في الخادم الحالي. أُوقفت أدوات الإعداد المحلية حتى لا توحي بحماية غير مطبقة.'
                        : 'Levels such as alerts-only or hiding location from a specific caregiver are not supported by the current server. Local configuration controls are disabled to avoid implying unenforced protection.',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                      height: 1.45,
                    ),
                  ),
                  if (app.care.consents.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        ar
                            ? 'تفضيلات المشاركة القديمة المحفوظة محليًا لا تثبت تطبيقها على الخادم.'
                            : 'Previously stored local preferences do not prove server enforcement.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
