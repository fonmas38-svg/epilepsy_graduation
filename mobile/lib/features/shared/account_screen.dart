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
      UserRole.patient => (const Color(0xFFEFF6FF), const Color(0xFF0066FF)),
      UserRole.doctor => (const Color(0xFFECFDF5), const Color(0xFF059669)),
      UserRole.caregiver => (const Color(0xFFFEF3C7), const Color(0xFFD97706)),
      UserRole.admin => (const Color(0xFFF3E8FF), const Color(0xFF7C3AED)),
      null => (const Color(0xFFF1F5F9), const Color(0xFF64748B)),
    };

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
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: const Color(0xFF0066FF), size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF0D253C),
                  ),
                ),
              ),
              Icon(
                ar ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                color: const Color(0xFF94A3B8),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );

    const divider = Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9), indent: 68);

    return Scaffold(
      backgroundColor: const Color(0xFFF6F9FD),
      appBar: AppBar(
        title: Text(
          ar ? 'حسابي' : 'Account',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF0D253C),
            fontSize: 19,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: !embedded,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE4EDF7), height: 1),
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
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFFE4EDF7), width: 1.2),
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
                    backgroundColor: const Color(0xFFEFF6FF),
                    child: const Icon(
                      Icons.person_rounded,
                      size: 44,
                      color: Color(0xFF0066FF),
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
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0D253C),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
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
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFFE4EDF7), width: 1.2),
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
                  if (user?.role == UserRole.admin) ...[
                    entry(
                      Icons.link_outlined,
                      ar
                          ? 'روابط الأطباء والمرافقين'
                          : 'Doctor & caregiver links',
                      Routes.adminLinks,
                    ),
                    divider,
                    entry(
                      Icons.manage_accounts_outlined,
                      ar ? 'إدارة الحسابات' : 'Manage accounts',
                      Routes.adminAccounts,
                    ),
                    divider,
                    entry(
                      Icons.devices_outlined,
                      ar ? 'إدارة الأجهزة' : 'Manage devices',
                      Routes.adminDevices,
                    ),
                    divider,
                  ],
                  if (user?.role == UserRole.patient) ...[
                    entry(
                      Icons.people_outline,
                      ar ? 'المرافقون' : 'Caregivers',
                      Routes.patientCaregivers,
                    ),
                    divider,
                    entry(
                      Icons.monitor_heart_outlined,
                      ar ? 'المراقبة المباشرة' : 'Live monitoring',
                      Routes.patientMonitoring,
                    ),
                    divider,
                    entry(
                      Icons.edit_note_outlined,
                      ar ? 'إضافة سجل يدوي' : 'Add a manual entry',
                      Routes.patientEntry,
                    ),
                    divider,
                    entry(
                      Icons.devices_outlined,
                      ar ? 'الجهاز والمراقبة' : 'Device & monitoring',
                      Routes.patientDevice,
                    ),
                    divider,
                    entry(
                      Icons.emergency_outlined,
                      ar
                          ? 'خطة الطوارئ وجهات الاتصال'
                          : 'Emergency plan & contacts',
                      Routes.patientEmergency,
                    ),
                    divider,
                    entry(
                      Icons.share_outlined,
                      ar ? 'المشاركة والصلاحيات' : 'Sharing & permissions',
                      Routes.patientConsents,
                    ),
                    divider,
                  ],
                  if (user?.role == UserRole.doctor) ...[
                    entry(
                      Icons.fact_check_outlined,
                      ar
                          ? 'مراجعة الأحداث والنوبات'
                          : 'Review events and seizures',
                      Routes.doctorAdjudication,
                    ),
                    divider,
                  ],
                  if (user != null && user.role != UserRole.admin) ...[
                    entry(
                      Icons.description_outlined,
                      ar ? 'التقارير' : 'Reports',
                      Routes.reports,
                    ),
                    divider,
                    entry(
                      Icons.chat_bubble_outline,
                      ar ? 'الرسائل' : 'Messages',
                      Routes.messages,
                    ),
                    divider,
                  ],
                  if (user?.role == UserRole.patient) ...[
                    entry(
                      Icons.event_note_outlined,
                      ar ? 'المحفزات والملاحظات' : 'Triggers and notes',
                      Routes.patientTriggers,
                    ),
                    divider,
                  ],
                  entry(
                    Icons.settings_outlined,
                    ar ? 'الإعدادات والخصوصية' : 'Settings & privacy',
                    Routes.patientSettings,
                  ),
                  divider,
                  entry(
                    Icons.security_outlined,
                    ar ? 'صلاحيات وأذونات النظام' : 'Device & system permissions',
                    Routes.devicePermissions,
                  ),
                  if (user != null) ...[
                    divider,
                    entry(
                      Icons.devices_other_outlined,
                      ar ? 'جلسات الدخول والأجهزة' : 'Sessions & devices',
                      Routes.accountSessions,
                    ),
                  ],
                  if (user?.role == UserRole.patient ||
                      user?.role == UserRole.admin) ...[
                    divider,
                    entry(
                      Icons.manage_accounts_outlined,
                      ar ? 'طلبات حذف الحساب' : 'Account erasure requests',
                      Routes.privacyRequests,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFFEE2E2), width: 1.2),
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF1F2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.logout_rounded,
                            color: Color(0xFFE11D48),
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
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFFE11D48),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                ar
                                    ? 'إنهاء جلسة هذا الحساب على الجهاز'
                                    : 'End this account session on the device',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          ar ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                          color: const Color(0xFFE11D48),
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
