import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/enums.dart';
import '../../core/router/route_names.dart';
import '../../core/ui/common.dart';
import '../../core/ui/session_actions.dart';
import '../../core/utils/doctor_title_formatter.dart';
import '../../providers/app_state.dart';

class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key, this.embedded = false});
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final user = app.auth.currentUser;
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final role = switch (user?.role) {
      UserRole.patient => ar ? 'مريض' : 'Patient',
      UserRole.caregiver => ar ? 'مرافق' : 'Caregiver',
      UserRole.doctor => ar ? 'طبيب' : 'Doctor',
      UserRole.admin => ar ? 'مشرف' : 'Administrator',
      null => '',
    };
    final (roleBg, roleColor) = switch (user?.role) {
      UserRole.patient => (
        AppColors.accent(context, AccentTone.blue).container,
        Theme.of(context).colorScheme.primary,
      ),
      UserRole.doctor => (
        AppColors.accent(context, AccentTone.green).container,
        AppColors.accent(context, AccentTone.green).foreground,
      ),
      UserRole.caregiver => (
        AppColors.accent(context, AccentTone.orange).container,
        AppColors.accent(context, AccentTone.orange).foreground,
      ),
      UserRole.admin => (
        AppColors.accent(context, AccentTone.indigo).container,
        AppColors.accent(context, AccentTone.indigo).foreground,
      ),
      null => (
        Theme.of(context).colorScheme.surfaceContainerLow,
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    };

    final userRole = user?.role;
    final patient = userRole == UserRole.patient;
    final accountItems = <(IconData, String, String)>[
      (
        Icons.settings_outlined,
        ar ? 'الإعدادات والخصوصية' : 'Settings & privacy',
        Routes.patientSettings,
      ),
      (
        Icons.security_outlined,
        ar ? 'صلاحيات وأذونات النظام' : 'Device & system permissions',
        Routes.devicePermissions,
      ),
      if (user != null)
        (
          Icons.devices_other_outlined,
          ar ? 'جلسات الدخول والأجهزة' : 'Sessions & devices',
          Routes.accountSessions,
        ),
      if (patient || userRole == UserRole.admin)
        (
          Icons.manage_accounts_outlined,
          ar ? 'طلبات حذف الحساب' : 'Account erasure requests',
          Routes.privacyRequests,
        ),
    ];
    final reports = (
      Icons.description_outlined,
      ar ? 'التقارير' : 'Reports',
      Routes.reports,
    );
    final messages = (
      Icons.chat_bubble_outline,
      ar ? 'الرسائل' : 'Messages',
      Routes.messages,
    );
    final groups = <({String title, List<(IconData, String, String)> items})>[
      if (userRole == UserRole.admin)
        (
          title: ar ? 'الإدارة' : 'Administration',
          items: [
            (
              Icons.link_outlined,
              ar ? 'روابط الأطباء والمرافقين' : 'Doctor & caregiver links',
              Routes.adminLinks,
            ),
            (
              Icons.manage_accounts_outlined,
              ar ? 'إدارة الحسابات' : 'Manage accounts',
              Routes.adminAccounts,
            ),
            (
              Icons.devices_outlined,
              ar ? 'إدارة الأجهزة' : 'Manage devices',
              Routes.adminDevices,
            ),
          ],
        ),
      if (patient) ...[
        (
          title: ar ? 'دائرة الرعاية' : 'Care circle',
          items: [
            (
              Icons.emergency_outlined,
              ar ? 'خطة الطوارئ وجهات الاتصال' : 'Emergency plan & contacts',
              Routes.patientEmergency,
            ),
            (
              Icons.people_outline,
              ar ? 'المرافقون' : 'Caregivers',
              Routes.patientCaregivers,
            ),
            (
              Icons.share_outlined,
              ar ? 'المشاركة والصلاحيات' : 'Sharing & permissions',
              Routes.patientConsents,
            ),
            messages,
          ],
        ),
        (
          title: ar ? 'المراقبة والسجلات' : 'Monitoring & records',
          items: [
            (
              Icons.monitor_heart_outlined,
              ar ? 'المراقبة المباشرة' : 'Live monitoring',
              Routes.patientMonitoring,
            ),
            (
              Icons.devices_outlined,
              ar ? 'الجهاز والمراقبة' : 'Device & monitoring',
              Routes.patientDevice,
            ),
            (
              Icons.edit_note_outlined,
              ar ? 'إضافة سجل يدوي' : 'Add a manual entry',
              Routes.patientEntry,
            ),
            (
              Icons.event_note_outlined,
              ar ? 'المحفزات والملاحظات' : 'Triggers and notes',
              Routes.patientTriggers,
            ),
            reports,
          ],
        ),
      ],
      if (userRole == UserRole.doctor)
        (
          title: ar ? 'العمل السريري' : 'Clinical work',
          items: [
            (
              Icons.fact_check_outlined,
              ar ? 'مراجعة الأحداث والنوبات' : 'Review events and seizures',
              Routes.doctorAdjudication,
            ),
            reports,
            messages,
          ],
        ),
      if (userRole == UserRole.caregiver)
        (title: ar ? 'الرعاية' : 'Care', items: [reports, messages]),
      (title: ar ? 'الحساب والتطبيق' : 'Account & app', items: accountItems),
    ];

    Widget entry(IconData icon, String title, String route) => Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.pushNamed(context, route),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  color: Theme.of(context).colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Icon(
                ar ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );

    final divider = Divider(
      height: 1,
      thickness: 1,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      indent: 68,
    );

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: Text(
          ar ? 'حسابي' : 'Account',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 19,
          ),
        ),
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: !embedded,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            color: Theme.of(context).colorScheme.outlineVariant,
            height: 1,
          ),
        ),
      ),
      body: ResponsiveContent(
        maxWidth: 720,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 1.2,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x06000000),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: AppColors.accent(
                      context,
                      AccentTone.blue,
                    ).container,
                    child: Icon(
                      Icons.person_rounded,
                      size: 44,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    user == null
                        ? ''
                        : DoctorTitleFormatter.format(
                            user.name,
                            role: user.role,
                            isArabic: ar,
                          ),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: roleBg,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      role,
                      style: TextStyle(
                        color: roleColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (user?.email != null && user!.email.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      user.email,
                      textAlign: TextAlign.center,
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Grouped by what the user is trying to do (care circle,
            // monitoring/records, account) instead of one long flat list.
            for (final g in groups) ...[
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 6, bottom: 8),
                child: Text(
                  g.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    width: 1.2,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x06000000),
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < g.items.length; i++) ...[
                      if (i > 0) divider,
                      entry(g.items[i].$1, g.items[i].$2, g.items[i].$3),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.of(context, RiskView.danger).border,
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
              clipBehavior: Clip.antiAlias,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => confirmSignOut(context, app),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: AppColors.accent(
                              context,
                              AccentTone.red,
                            ).container,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.logout_rounded,
                            color: AppColors.of(
                              context,
                              RiskView.danger,
                            ).foreground,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ar ? 'تسجيل الخروج' : 'Sign out',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.of(
                                    context,
                                    RiskView.danger,
                                  ).foreground,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                ar
                                    ? 'إنهاء جلسة هذا الحساب على الجهاز'
                                    : 'End this account session on the device',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          ar
                              ? Icons.chevron_left_rounded
                              : Icons.chevron_right_rounded,
                          color: AppColors.of(
                            context,
                            RiskView.danger,
                          ).foreground,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
