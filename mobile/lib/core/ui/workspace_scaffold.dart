import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import '../../widgets/app_drawer.dart';
import '../enums.dart';
import '../router/route_names.dart';

/// Shared desktop navigation. Compact layouts retain their native page controls.
class WorkspaceScaffold extends StatelessWidget {
  const WorkspaceScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.destinations,
    this.selectedIndex,
    this.onDestinationSelected,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final List<NavigationDestination>? destinations;
  final int? selectedIndex;
  final ValueChanged<int>? onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l = AppLocalizations.of(context);
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final role = app.auth.currentUser?.role;
    final routes = switch (role) {
      UserRole.doctor => [
        Routes.doctor,
        Routes.doctorAdjudication,
        Routes.messages,
        Routes.account,
      ],
      UserRole.caregiver => [Routes.family, Routes.messages, Routes.account],
      UserRole.admin => [
        Routes.admin,
        Routes.adminAccounts,
        Routes.adminDevices,
        Routes.account,
      ],
      _ => [
        Routes.patient,
        Routes.patientHistory,
        Routes.patientMedications,
        Routes.account,
      ],
    };
    final entries =
        destinations ??
        switch (role) {
          UserRole.doctor => [
            NavigationDestination(
              icon: const Icon(Icons.people_outline),
              label: l.patientsList,
            ),
            NavigationDestination(
              icon: const Icon(Icons.fact_check_outlined),
              label: ar ? 'المراجعات' : 'Reviews',
            ),
            NavigationDestination(
              icon: const Icon(Icons.chat_bubble_outline),
              label: ar ? 'الرسائل' : 'Messages',
            ),
            NavigationDestination(
              icon: const Icon(Icons.person_outline),
              label: ar ? 'حسابي' : 'Account',
            ),
          ],
          UserRole.caregiver => [
            NavigationDestination(
              icon: const Icon(Icons.people_outline),
              label: ar ? 'مرضاي' : 'Patients',
            ),
            NavigationDestination(
              icon: const Icon(Icons.chat_bubble_outline),
              label: ar ? 'الرسائل' : 'Messages',
            ),
            NavigationDestination(
              icon: const Icon(Icons.person_outline),
              label: ar ? 'حسابي' : 'Account',
            ),
          ],
          UserRole.admin => [
            NavigationDestination(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: ar ? 'الإدارة' : 'Administration',
            ),
            NavigationDestination(
              icon: const Icon(Icons.manage_accounts_outlined),
              label: ar ? 'الحسابات' : 'Accounts',
            ),
            NavigationDestination(
              icon: const Icon(Icons.devices_outlined),
              label: ar ? 'الأجهزة' : 'Devices',
            ),
            NavigationDestination(
              icon: const Icon(Icons.person_outline),
              label: ar ? 'حسابي' : 'Account',
            ),
          ],
          _ => [
            NavigationDestination(
              icon: const Icon(Icons.home_outlined),
              label: l.tabHome,
            ),
            NavigationDestination(
              icon: const Icon(Icons.history),
              label: l.tabHistory,
            ),
            NavigationDestination(
              icon: const Icon(Icons.medication_outlined),
              label: l.tabMeds,
            ),
            NavigationDestination(
              icon: const Icon(Icons.person_outline),
              label: ar ? 'حسابي' : 'Account',
            ),
          ],
        };
    void select(int index) {
      if (onDestinationSelected != null) {
        onDestinationSelected!(index);
      } else if (index != 0) {
        Navigator.pushNamed(context, routes[index]);
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final extended =
            constraints.maxWidth >= 1250 &&
            MediaQuery.textScalerOf(context).scale(14) <= 21;
        return Scaffold(
          drawer: wide ? null : const AppDrawer(),
          appBar: appBar,
          floatingActionButton: floatingActionButton,
          bottomNavigationBar: wide
              ? null
              : bottomNavigationBar ??
                    NavigationBar(
                      selectedIndex: selectedIndex ?? 0,
                      onDestinationSelected: select,
                      destinations: entries,
                    ),
          body: Row(
            children: [
              if (wide) ...[
                NavigationRail(
                  scrollable: true,
                  extended: extended,
                  labelType: extended
                      ? NavigationRailLabelType.none
                      : NavigationRailLabelType.all,
                  selectedIndex: selectedIndex ?? 0,
                  onDestinationSelected: select,
                  leading: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      Icons.monitor_heart_outlined,
                      color: Theme.of(context).colorScheme.primary,
                      size: 32,
                    ),
                  ),
                  destinations: entries
                      .map(
                        (entry) => NavigationRailDestination(
                          icon: entry.icon,
                          selectedIcon: entry.selectedIcon,
                          label: Text(entry.label),
                        ),
                      )
                      .toList(),
                ),
                const VerticalDivider(width: 1),
              ],
              Expanded(child: body),
            ],
          ),
        );
      },
    );
  }
}
