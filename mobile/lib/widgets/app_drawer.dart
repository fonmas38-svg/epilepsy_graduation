import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/enums.dart';
import '../core/router/app_router.dart';
import '../core/router/route_names.dart';
import '../core/ui/session_actions.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_state.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l = AppLocalizations.of(context);
    final ar = l.isArabic;
    final user = app.auth.currentUser;
    final entries = <(IconData, String, String)>[
      (
        Icons.home_outlined,
        ar ? 'الرئيسية' : 'Home',
        AppRouter.rootFor(user?.role),
      ),
      if (user?.role == UserRole.patient) ...[
        (
          Icons.monitor_heart_outlined,
          ar ? 'المراقبة' : 'Monitoring',
          Routes.patientMonitoring,
        ),
        (
          Icons.emergency_outlined,
          ar ? 'خطة الطوارئ' : 'Emergency plan',
          Routes.patientEmergency,
        ),
        (Icons.description_outlined, l.reportsTitle, Routes.reports),
        (Icons.event_note_outlined, l.triggersTitle, Routes.patientTriggers),
      ],
      if (user?.role == UserRole.doctor)
        (
          Icons.fact_check_outlined,
          ar ? 'مراجعة الأحداث' : 'Event reviews',
          Routes.doctorAdjudication,
        ),
      if (user?.role != UserRole.admin)
        (
          Icons.chat_bubble_outline,
          ar ? 'الرسائل' : 'Messages',
          Routes.messages,
        ),
      if (user?.role == UserRole.admin) ...[
        (
          Icons.link_outlined,
          ar ? 'روابط الرعاية' : 'Care links',
          Routes.adminLinks,
        ),
        (
          Icons.manage_accounts_outlined,
          ar ? 'الحسابات' : 'Accounts',
          Routes.adminAccounts,
        ),
        (
          Icons.devices_outlined,
          ar ? 'الأجهزة' : 'Devices',
          Routes.adminDevices,
        ),
      ],
      (Icons.person_outline, ar ? 'حسابي' : 'Account', Routes.account),
    ];
    void open(String route) {
      final current = ModalRoute.of(context)?.settings.name;
      Navigator.pop(context);
      if (current == route) return;
      if (route == AppRouter.rootFor(user?.role)) {
        Navigator.pushNamedAndRemoveUntil(context, route, (_) => false);
      } else {
        Navigator.pushNamed(context, route);
      }
    }

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    child: Icon(
                      Icons.person_outline,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.name ?? l.appTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(switch (user?.role) {
                          UserRole.patient => l.rolePatient,
                          UserRole.doctor => l.roleDoctor,
                          UserRole.caregiver => l.roleCaregiver,
                          UserRole.admin => l.roleAdmin,
                          null => '',
                        }),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: entries
                    .map(
                      (entry) => ListTile(
                        leading: Icon(entry.$1),
                        title: Text(entry.$2),
                        selected:
                            ModalRoute.of(context)?.settings.name == entry.$3,
                        onTap: () => open(entry.$3),
                      ),
                    )
                    .toList(),
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: Text(l.logout),
              onTap: () {
                Navigator.pop(context);
                confirmSignOut(context, app);
              },
            ),
          ],
        ),
      ),
    );
  }
}
