import '../../core/theme/app_colors.dart';
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
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: Text(
          ar ? 'المشاركة والصلاحيات' : 'Sharing and permissions',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 19,
          ),
        ),
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(
          color: Theme.of(context).colorScheme.onSurface,
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            color: Theme.of(context).colorScheme.outlineVariant,
            height: 1,
          ),
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
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 1.2,
                ),
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
                          color: AppColors.accent(
                            context,
                            AccentTone.blue,
                          ).container,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.people_outline_rounded,
                          color: Theme.of(context).colorScheme.primary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          ar
                              ? 'التحكم في وصول المرافقين'
                              : 'Manage caregiver access',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    ar
                        ? 'يمكنك السماح للمرافق برؤية بياناتك أو إيقاف ذلك من صفحة المرافقين. محادثتك الخاصة مع طبيبك لا يراها المرافق أبدًا.'
                        : 'Allow or stop a caregiver seeing your data from the caregivers page. Your private chat with your doctor is never shown to caregivers.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
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
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 1.2,
                ),
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
                          color: AppColors.accent(
                            context,
                            AccentTone.orange,
                          ).container,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.shield_outlined,
                          color: AppColors.accent(
                            context,
                            AccentTone.orange,
                          ).foreground,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          ar
                              ? 'مستويات المشاركة التفصيلية'
                              : 'Detailed sharing levels',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    ar
                        ? 'خيارات المشاركة الجزئية (مثل «التنبيهات فقط» أو إخفاء الموقع عن مرافق معيّن) غير متاحة بعد. المرافق المرتبط يرى التنبيهات والموقع وقت الطوارئ.'
                        : 'Partial sharing (such as alerts-only, or hiding location from one caregiver) is not available yet. A linked caregiver sees alerts and location during emergencies.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  if (app.care.consents.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        ar
                            ? 'تفضيلات المشاركة القديمة على هذا الهاتف لم تعد مستخدمة.'
                            : 'Older sharing preferences stored on this phone are no longer used.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
