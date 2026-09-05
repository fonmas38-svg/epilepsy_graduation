import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/enums.dart';
import '../core/router/route_names.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/risk_indicator.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_state.dart';

/// Unified Medical Navigation Drawer (Sidebar) across all user roles.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  void _navigate(BuildContext context, String targetRoute) {
    Navigator.pop(context); // Close the drawer first
    final current = ModalRoute.of(context)?.settings.name;
    if (current == targetRoute) return;

    // Use pushReplacement if navigating to home roots to keep stack clean
    if (targetRoute == Routes.patient ||
        targetRoute == Routes.doctor ||
        targetRoute == Routes.family) {
      Navigator.pushNamedAndRemoveUntil(context, targetRoute, (r) => false);
    } else {
      Navigator.pushNamed(context, targetRoute);
    }
  }

  Future<void> _logout(BuildContext context, AppState app, AppLocalizations l) async {
    Navigator.pop(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.logout),
        content: Text(l.logoutConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l.logout),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await app.signOut();
      if (context.mounted) {
        Navigator.pushNamedAndRemoveUntil(context, Routes.login, (r) => false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final user = app.auth.currentUser;
    final role = user?.role ?? UserRole.patient;

    final roleLabel = switch (role) {
      UserRole.patient => l.rolePatient,
      UserRole.doctor => l.roleDoctor,
      UserRole.caregiver => l.roleCaregiver,
    };

    final roleIcon = switch (role) {
      UserRole.patient => Icons.favorite_rounded,
      UserRole.doctor => Icons.medical_services_rounded,
      UserRole.caregiver => Icons.family_restroom_rounded,
    };

    final riskTone = AppColors.of(context, app.riskView);

    return Drawer(
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // --- Header ---
            Container(
              width: double.infinity,
              padding: const EdgeInsets.only(
                top: 52,
                left: Gap.md,
                right: Gap.md,
                bottom: Gap.md,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.colorScheme.primaryContainer,
                    theme.colorScheme.surface,
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        child: Icon(roleIcon, size: 28),
                      ),
                      Gap.hMd,
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?.name.isNotEmpty == true ? user!.name : l.appTitle,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Gap.vXs,
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Gap.sm,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(Radii.pill),
                              ),
                              child: Text(
                                roleLabel,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Gap.vSm,
                  // Status Pill (Patient only)
                  if (role == UserRole.patient)
                    Container(
                      margin: const EdgeInsets.only(top: Gap.xs),
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
                      decoration: BoxDecoration(
                        color: riskTone.container,
                        borderRadius: BorderRadius.circular(Radii.sm),
                        border: Border.all(color: riskTone.solid.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.shield_outlined, size: 14, color: riskTone.foreground),
                          Gap.hXs,
                          Text(
                            'الحالة: ${RiskCopy.title(app.riskView, l)}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: riskTone.foreground,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Gap.vXs,
                  // Online indicator
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: app.apiOnline ? Colors.green : Colors.amber,
                        ),
                      ),
                      Gap.hXs,
                      Text(
                        app.apiOnline ? l.deviceConnected : l.deviceDisconnected,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // --- Menu Items ---
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                children: [
                  if (role == UserRole.patient) ...[
                    _DrawerTile(
                      icon: Icons.dashboard_outlined,
                      title: l.patientHome,
                      onTap: () => _navigate(context, Routes.patient),
                    ),
                    _DrawerTile(
                      icon: Icons.monitor_heart_outlined,
                      title: 'محاكي الإشارات الحيوية والتصعيد',
                      subtitle: 'نبض القلب، موجات الدماغ، وتصعيد التنبيه',
                      badge: 'مباشر',
                      onTap: () => _navigate(context, Routes.patientSimulator),
                    ),
                    _DrawerTile(
                      icon: Icons.chat_bubble_outline,
                      title: l.messagesTitle,
                      subtitle: 'استشارات الطبيب ورعاية الأسرة',
                      onTap: () => _navigate(context, Routes.messages),
                    ),
                    _DrawerTile(
                      icon: Icons.medication_outlined,
                      title: l.medsTitle,
                      onTap: () => _navigate(context, Routes.patientMedications),
                    ),
                    _DrawerTile(
                      icon: Icons.calendar_month_outlined,
                      title: l.historyTitle,
                      onTap: () => _navigate(context, Routes.patientHistory),
                    ),
                    _DrawerTile(
                      icon: Icons.emergency_outlined,
                      title: l.emergencyTitle,
                      onTap: () => _navigate(context, Routes.patientEmergency),
                    ),
                    _DrawerTile(
                      icon: Icons.bolt_outlined,
                      title: l.triggersTitle,
                      onTap: () => _navigate(context, Routes.patientTriggers),
                    ),
                    _DrawerTile(
                      icon: Icons.table_chart_outlined,
                      title: 'التقارير الطبية وتصدير Excel',
                      onTap: () => _navigate(context, Routes.reports),
                    ),
                    _DrawerTile(
                      icon: Icons.security_outlined,
                      title: l.consentsTitle,
                      onTap: () => _navigate(context, Routes.patientConsents),
                    ),
                    _DrawerTile(
                      icon: Icons.settings_outlined,
                      title: l.settingsTitle,
                      onTap: () => _navigate(context, Routes.patientSettings),
                    ),
                  ] else if (role == UserRole.doctor) ...[
                    _DrawerTile(
                      icon: Icons.groups_outlined,
                      title: l.doctorHome,
                      onTap: () => _navigate(context, Routes.doctor),
                    ),
                    _DrawerTile(
                      icon: Icons.chat_bubble_outline,
                      title: 'الرسائل والاستشارات السريرية',
                      onTap: () => _navigate(context, Routes.messages),
                    ),
                    _DrawerTile(
                      icon: Icons.gavel_outlined,
                      title: l.adjudicationTitle,
                      onTap: () => _navigate(context, Routes.doctorAdjudication),
                    ),
                    _DrawerTile(
                      icon: Icons.table_chart_outlined,
                      title: 'التقارير الطبية وتصدير Excel',
                      onTap: () => _navigate(context, Routes.reports),
                    ),
                    _DrawerTile(
                      icon: Icons.settings_outlined,
                      title: l.settingsTitle,
                      onTap: () => _navigate(context, Routes.patientSettings),
                    ),
                  ] else if (role == UserRole.caregiver) ...[
                    _DrawerTile(
                      icon: Icons.family_restroom_outlined,
                      title: l.familyHome,
                      onTap: () => _navigate(context, Routes.family),
                    ),
                    _DrawerTile(
                      icon: Icons.chat_bubble_outline,
                      title: 'محادثة الأسرة والمريض',
                      onTap: () => _navigate(context, Routes.messages),
                    ),
                    _DrawerTile(
                      icon: Icons.table_chart_outlined,
                      title: 'التقارير الطبية وتصدير Excel',
                      onTap: () => _navigate(context, Routes.reports),
                    ),
                    _DrawerTile(
                      icon: Icons.settings_outlined,
                      title: l.settingsTitle,
                      onTap: () => _navigate(context, Routes.patientSettings),
                    ),
                  ],
                ],
              ),
            ),

            // --- Logout footer ---
            const Divider(height: 1),
            _DrawerTile(
              icon: Icons.logout_rounded,
              title: l.logout,
              color: theme.colorScheme.error,
              onTap: () => _logout(context, app, l),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.badge,
    this.color,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final String? subtitle;
  final String? badge;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = color ?? theme.colorScheme.onSurface;

    return ListTile(
      leading: Icon(icon, color: color ?? theme.colorScheme.primary),
      title: Text(
        title,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: effectiveColor,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: badge != null
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text(
                badge!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                ),
              ),
            )
          : const Icon(Icons.chevron_left, size: 18),
      onTap: onTap,
    );
  }
}
