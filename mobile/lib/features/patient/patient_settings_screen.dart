import 'dart:async';
import '../../core/router/route_names.dart';
import '../../core/ui/session_actions.dart';
import '../shared/change_password_dialog.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../core/enums.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/utils/doctor_title_formatter.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import '../../services/biometric_service.dart';
import '../../services/report_service.dart';
import '../../services/settings_service.dart';
import '../../widgets/care_sync_status_card.dart';

/// §3.6 — the patient's own settings.
///
/// Three rules are enforced structurally rather than left to the copy:
///
/// * Sensitivity is presented as a **trade-off with both sides stated** — every
///   option shows what it catches *and* what it costs in false alarms, taken from
///   the same [AlertSensitivity] table the alerting path reads.
/// * Quiet hours can never silence a high-risk alert. The screen says so, and
///   `SettingsService.mayMute` refuses regardless of what this screen shows.
/// * «من يُبلَّغ» has a row for high risk that is deliberately **not** a switch,
///   because it is not a choice.
class PatientSettingsScreen extends StatelessWidget {
  const PatientSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // `AppState` forwards `SettingsService`'s notifications as its own, so
    // watching the app state is enough to repaint on every preference change.
    final app = context.watch<AppState>();
    final s = app.settings;
    final isPatient = app.auth.currentUser?.role == UserRole.patient;

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: ResponsiveContent(
        maxWidth: 860,
        child: ListView(
          padding: Insets.pageBottomSafe,
          children: [
            const CareSyncStatusCard(),
            Gap.vMd,
            _AppearanceSection(settings: s),
            Gap.vMd,
            if (isPatient) ...[
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () =>
                      Navigator.pushNamed(context, Routes.patientCaregivers),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.all(16),
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
                    child: Row(
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.isArabic ? 'المرافقون' : 'Caregivers',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l.isArabic
                                    ? 'إضافة مرافق وإدارة وصوله إلى بياناتك'
                                    : 'Add caregivers and manage access to your data',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          l.isArabic
                              ? Icons.chevron_left_rounded
                              : Icons.chevron_right_rounded,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          size: 22,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Gap.vMd,
              _NotifySection(settings: s),
              Gap.vMd,
              _QuietHoursSection(settings: s),
              Gap.vMd,
            ],
            const _PrivacySection(),
            Gap.vMd,
            if (isPatient)
              Card(
                child: ExpansionTile(
                  title: Text(
                    l.isArabic
                        ? 'إعدادات المراقبة المتقدمة'
                        : 'Advanced monitoring settings',
                  ),
                  leading: const Icon(Icons.tune),
                  childrenPadding: const EdgeInsets.all(12),
                  children: [
                    InfoNote(
                      text: l.isArabic
                          ? 'تغيير حساسية النموذج لكل مريض غير متاح حاليًا. لا توجد نسب كشف أو إنذارات خاطئة موثقة لهذه الخيارات.'
                          : 'Per-patient model sensitivity is not configurable yet. Validated detection and false-alarm rates are unavailable.',
                    ),
                    Gap.vMd,
                    _HorizonSection(app: app),
                  ],
                ),
              ),
            Gap.vMd,
            const _AboutSection(),
          ],
        ),
      ),
    );
  }
}

// --- sensitivity ------------------------------------------------------------

// --- horizon ----------------------------------------------------------------

class _HorizonSection extends StatefulWidget {
  const _HorizonSection({required this.app});

  final AppState app;

  @override
  State<_HorizonSection> createState() => _HorizonSectionState();
}

class _HorizonSectionState extends State<_HorizonSection> {
  /// Non-null only while the thumb is being dragged.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final value = (_dragging ?? widget.app.preictalHorizonMin).clamp(
      AppConfig.minHorizonMin,
      AppConfig.maxHorizonMin,
    );

    return SectionCard(
      title: l.horizonTitle,
      icon: Icons.hourglass_bottom_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledValue(
            label: l.horizonTitle,
            value: '${value.round()} ${l.minutesUnit}',
            icon: Icons.schedule_outlined,
          ),
          Slider(
            value: value,
            min: AppConfig.minHorizonMin,
            max: AppConfig.maxHorizonMin,
            divisions: ((AppConfig.maxHorizonMin - AppConfig.minHorizonMin) / 5)
                .round(),
            label: '${value.round()}',
            onChanged: (v) => setState(() => _dragging = v),
            // Persisted on release, not on every drag frame: writing a
            // preference 25 times per swipe is pointless churn.
            onChangeEnd: (v) async {
              await widget.app.setPreictalHorizonMin(v);
              if (mounted) setState(() => _dragging = null);
            },
          ),
          InfoNote(text: l.horizonNote),
        ],
      ),
    );
  }
}

// --- quiet hours ------------------------------------------------------------

class _QuietHoursSection extends StatelessWidget {
  const _QuietHoursSection({required this.settings});

  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return SectionCard(
      title: l.quietHours,
      icon: Icons.nightlight_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            value: settings.quietHoursEnabled,
            contentPadding: EdgeInsets.zero,
            onChanged: (v) => settings.setQuietHoursEnabled(v),
            title: Text(l.quietHours),
            secondary: const Icon(Icons.volume_off_outlined),
          ),
          if (settings.quietHoursEnabled)
            Row(
              children: [
                Expanded(
                  child: _TimeButton(
                    label: l.quietFrom,
                    time: settings.quietStart,
                    onPick: (t) =>
                        settings.setQuietWindow(t, settings.quietEnd),
                  ),
                ),
                Gap.hSm,
                Expanded(
                  child: _TimeButton(
                    label: l.quietTo,
                    time: settings.quietEnd,
                    onPick: (t) =>
                        settings.setQuietWindow(settings.quietStart, t),
                  ),
                ),
              ],
            ),
          Gap.vSm,
          // Caution, not neutral: this is the one line that stops a patient from
          // believing quiet hours can silence a seizure warning.
          InfoNote(
            text: l.quietHoursNote,
            icon: Icons.lock_clock_outlined,
            view: RiskView.caution,
          ),
        ],
      ),
    );
  }
}

class _TimeButton extends StatelessWidget {
  const _TimeButton({
    required this.label,
    required this.time,
    required this.onPick,
  });

  final String label;
  final TimeOfDay time;
  final void Function(TimeOfDay picked) onPick;

  @override
  Widget build(BuildContext context) {
    final text =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    return SizedBox(
      height: A11y.minTouchTarget,
      child: OutlinedButton.icon(
        onPressed: () async {
          final picked = await showTimePicker(
            context: context,
            initialTime: time,
          );
          if (picked != null) onPick(picked);
        },
        icon: const Icon(Icons.access_time_outlined),
        label: Text('$label $text'),
      ),
    );
  }
}

// --- who gets notified ------------------------------------------------------

class _NotifySection extends StatelessWidget {
  const _NotifySection({required this.settings});

  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return SectionCard(
      title: l.notifySection,
      icon: Icons.family_restroom_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            value: settings.notifyFamilyOnCaution,
            contentPadding: EdgeInsets.zero,
            onChanged: (v) => settings.setNotifyFamilyOnCaution(v),
            title: Text(l.notifyOnCaution),
            secondary: const Icon(Icons.notifications_none_outlined),
          ),
          // Rendered as a fact, not a switch. Making it look toggleable and then
          // ignoring it would be worse than not showing it at all.
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notification_important_outlined),
            title: Text(l.notifyOnDanger),
            trailing: const Icon(Icons.check_circle_outline),
            subtitle: Text(l.notifyAlwaysDanger),
          ),
          SwitchListTile(
            value: settings.shareLocationOnAlert,
            contentPadding: EdgeInsets.zero,
            onChanged: (v) => settings.setShareLocationOnAlert(v),
            title: Text(l.shareLocation),
            secondary: const Icon(Icons.my_location_outlined),
          ),
        ],
      ),
    );
  }
}

// --- appearance -------------------------------------------------------------

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection({required this.settings});

  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return SectionCard(
      title: l.appearance,
      icon: Icons.palette_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _ThemePreviewCard(
                  title: l.themeLight,
                  icon: Icons.light_mode_outlined,
                  isSelected: settings.themeMode == ThemeMode.light,
                  onTap: () => settings.setThemeMode(ThemeMode.light),
                  bgColor: Theme.of(context).colorScheme.surface,
                  textColor: Theme.of(context).colorScheme.onSurface,
                  accentColor: const Color(0xFF1B4965),
                ),
              ),
              Gap.hSm,
              Expanded(
                child: _ThemePreviewCard(
                  title: l.themeDark,
                  icon: Icons.dark_mode_outlined,
                  isSelected: settings.themeMode == ThemeMode.dark,
                  onTap: () => settings.setThemeMode(ThemeMode.dark),
                  bgColor: const Color(0xFF121E28),
                  textColor: Colors.white,
                  accentColor: const Color(0xFF62B6CB),
                ),
              ),
              Gap.hSm,
              Expanded(
                child: _ThemePreviewCard(
                  title: l.themeSystem,
                  icon: Icons.brightness_auto_outlined,
                  isSelected: settings.themeMode == ThemeMode.system,
                  onTap: () => settings.setThemeMode(ThemeMode.system),
                  bgColor: theme.colorScheme.surfaceContainerHighest,
                  textColor: theme.colorScheme.onSurface,
                  accentColor: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          Gap.vMd,
          Text(l.language, style: theme.textTheme.labelLarge),
          Gap.vXs,
          SegmentedButton<String>(
            selected: {settings.localeCode ?? ''},
            onSelectionChanged: (set) =>
                settings.setLocaleCode(set.first.isEmpty ? null : set.first),
            segments: [
              ButtonSegment(
                value: '',
                label: Text(l.themeSystem),
                icon: const Icon(Icons.translate_outlined),
              ),
              ButtonSegment(value: 'ar', label: Text(l.languageArabic)),
              ButtonSegment(value: 'en', label: Text(l.languageEnglish)),
            ],
          ),
          Gap.vMd,
          InfoNote(
            text: l.reduceMotionNote,
            icon: Icons.accessibility_new_outlined,
          ),
        ],
      ),
    );
  }
}

class _ThemePreviewCard extends StatelessWidget {
  const _ThemePreviewCard({
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    required this.bgColor,
    required this.textColor,
    required this.accentColor,
  });

  final String title;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final Color bgColor;
  final Color textColor;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: const EdgeInsets.symmetric(
          vertical: Gap.md,
          horizontal: Gap.xs,
        ),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: isSelected
                ? accentColor
                : Colors.grey.withValues(alpha: 0.3),
            width: isSelected ? 2.5 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.25),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Column(
          children: [
            Icon(icon, color: isSelected ? accentColor : textColor, size: 24),
            const SizedBox(height: Gap.xs),
            Text(
              title,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// --- privacy ----------------------------------------------------------------

class _PrivacySection extends StatefulWidget {
  const _PrivacySection();

  @override
  State<_PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends State<_PrivacySection> {
  final _reports = ReportService();
  final _biometrics = BiometricService();
  bool _busy = false;
  bool _biometricsAvailable = false;
  bool _biometricsEnabled = false;

  @override
  void initState() {
    super.initState();
    _checkBiometrics();
  }

  Future<void> _checkBiometrics() async {
    final app = context.read<AppState>();
    final user = app.auth.currentUser;
    final u =
        app.currentSessionUsername ??
        (user?.role == UserRole.patient
            ? 'patient'
            : (user?.email.split('@').first ?? 'user'));
    final avail = await _biometrics.isAvailable;
    final enabled = await _biometrics.isEnabledForUser(u);
    if (mounted) {
      setState(() {
        _biometricsAvailable = avail;
        _biometricsEnabled = enabled;
      });
    }
  }

  Future<void> _toggleBiometrics(bool enable) async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final user = app.auth.currentUser;
    final u =
        app.currentSessionUsername ??
        (user?.role == UserRole.patient
            ? 'patient'
            : (user?.email.split('@').first ?? 'user'));

    if (enable) {
      final success = await _biometrics.authenticate(
        localizedReason: l.biometricPromptReason,
      );
      if (!success) {
        if (mounted) {
          AppSnack.warn(
            context,
            _biometrics.lastErrorMessage ??
                'لم يتم التحقق من البصمة عبر المستشعر',
          );
        }
        return;
      }
      final token = await app.api.tokens.bearer();
      if (token == null || user == null || app.auth.isDemoSession) {
        if (mounted) AppSnack.warn(context, l.signIn);
        return;
      }
      final enabled = await _biometrics.enableForUser(
        username: u,
        userId: user.uid,
        token: token,
        role: user.role.name,
        baseUrl: app.api.baseUrl,
      );
      if (!enabled) {
        if (mounted) AppSnack.warn(context, l.signIn);
        return;
      }
    } else {
      await _biometrics.disableForUser(u);
    }
    if (mounted) {
      setState(() => _biometricsEnabled = enable);
      final displayAccount = user != null
          ? DoctorTitleFormatter.format(
              user.name.isNotEmpty ? user.name : u,
              role: user.role,
              isArabic: l.isArabic,
            )
          : u;
      AppSnack.success(
        context,
        enable
            ? 'تم تفعيل تسجيل الدخول بالبصمة لحساب «$displayAccount»'
            : 'تم تعطيل الدخول بالبصمة لحساب «$displayAccount»',
      );
    }
  }

  Future<void> _showChangePasswordDialog() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const ChangePasswordDialog(),
  );

  Future<void> _export() async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final pid = app.activePatientId;
    final profile = pid == null ? null : app.auth.patientById(pid);
    if (pid == null || profile == null) {
      AppSnack.warn(context, l.noPatientSelected);
      return;
    }
    setState(() => _busy = true);
    AppSnack.show(context, l.exportStarted);
    try {
      final doc = await _reports.toPdf(
        patient: profile,
        assessments: await app.db.assessmentsFor(
          pid,
          limit: 500,
          serverOrigin: app.dataOrigin,
        ),
        alerts: await app.db.alertsFor(
          pid,
          limit: 200,
          serverOrigin: app.dataOrigin,
        ),
      );
      final pdfBytes = await doc.save();
      // Automatic backup to Supabase Cloud Storage (best-effort)
      unawaited(
        app.api
            .uploadReport(
              patientId: pid,
              filename:
                  'clinical_report_${profile.name.isNotEmpty ? profile.name : pid}.pdf',
              bytes: pdfBytes,
            )
            .then((res) {
              if (res['url'] != null) {
                debugPrint('[Supabase Storage] Report synced: ${res['url']}');
              }
            })
            .catchError((e) {
              debugPrint('[Supabase Storage] Report sync deferred: $e');
            }),
      );
      // The OS print sheet *is* the export: it offers «حفظ بصيغة PDF» and share
      // targets without the app needing storage permission or a file picker.
      await Printing.layoutPdf(onLayout: (_) => Future.value(pdfBytes));
      // Recorded like any other read of this patient's data, so the access log
      // in §4.3 stays complete — including the patient's own exports.
      await app.care.recordAccess('exported');
      if (mounted) AppSnack.success(context, l.reportReady);
    } catch (_) {
      if (mounted) AppSnack.error(context, l.exportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestDeletion() async {
    await Navigator.pushNamed(context, Routes.privacyRequests);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final s = app.settings;
    final isPatient = app.auth.currentUser?.role == UserRole.patient;
    return SectionCard(
      title: l.privacySection,
      icon: Icons.shield_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_biometricsAvailable) ...[
            SwitchListTile(
              value: _biometricsEnabled,
              contentPadding: EdgeInsets.zero,
              onChanged: _toggleBiometrics,
              title: Text(l.biometricsEnabled),
              subtitle: Text(l.biometricsEnabledDesc),
              secondary: const Icon(Icons.fingerprint),
            ),
            Gap.vXs,
          ],
          SwitchListTile(
            value: s.autoLockEnabled,
            contentPadding: EdgeInsets.zero,
            onChanged: (val) => s.setAutoLockEnabled(val),
            title: Text(
              l.isArabic
                  ? 'القفل التلقائي عند الخمول'
                  : 'Auto-Lock on Inactivity',
            ),
            subtitle: Text(
              l.isArabic
                  ? 'قفل شاشة التطبيق لحماية خصوصية البيانات الطبية'
                  : 'Lock app screen after inactivity to protect clinical privacy',
            ),
            secondary: const Icon(Icons.lock_clock_outlined),
          ),
          if (s.autoLockEnabled) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.isArabic
                        ? 'مهلة الخمول قبل القفل:'
                        : 'Inactivity timeout:',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final m in [5, 10, 15, 30])
                        ChoiceChip(
                          label: Text(
                            l.isArabic ? '$m دقائق' : '$m min',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: s.autoLockMinutes == m
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          selected: s.autoLockMinutes == m,
                          onSelected: (_) => s.setAutoLockMinutes(m),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l.isArabic
                        ? 'تلميح لمناقشة التخرج: يمكنك اختيار 15-30 دقيقة أو إيقاف القفل مؤقتاً لتجنب المقاطعة أثناء الشرح.'
                        : 'Tip for presentations: You can choose 15-30 min or disable lock temporarily to avoid interruptions.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
          Gap.vSm,
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: _showChangePasswordDialog,
              icon: const Icon(Icons.password_outlined),
              label: Text(l.changePassword),
            ),
          ),
          Gap.vSm,
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: () =>
                  Navigator.pushNamed(context, Routes.devicePermissions),
              icon: const Icon(Icons.security_outlined),
              label: Text(
                Localizations.localeOf(context).languageCode == 'ar'
                    ? 'صلاحيات وأذونات النظام'
                    : 'Device & System Permissions',
              ),
            ),
          ),
          // Data export and account deletion are patient-only features
          if (isPatient) ...[
            Gap.vMd,
            SizedBox(
              height: A11y.minTouchTarget,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.download_outlined),
                label: Text(l.exportMyData),
              ),
            ),
            Gap.vXs,
            Text(
              l.exportMyDataNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Gap.vMd,
            SizedBox(
              height: A11y.minTouchTarget,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _requestDeletion,
                icon: const Icon(Icons.delete_forever_outlined),
                label: Text(l.deleteAccount),
              ),
            ),
            Gap.vSm,
            InfoNote(text: l.deleteAccountNote, icon: Icons.gavel_outlined),
          ],
        ],
      ),
    );
  }
}

// --- about -------------------------------------------------------------------

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final app = context.read<AppState>();
    final user = app.auth.currentUser;
    final roleName = switch (user?.role) {
      UserRole.patient => 'مريض',
      UserRole.doctor => 'طبيب',
      UserRole.caregiver => 'مرافق / أسرة',
      UserRole.admin => 'مدير النظام',
      null => '',
    };

    return SectionCard(
      title: 'حول النظام',
      icon: Icons.info_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: ClipOval(
              child: Image.asset(
                'assets/images/app_logo.png',
                width: 40,
                height: 40,
                fit: BoxFit.cover,
              ),
            ),
            title: Text(l.appTitle),
            subtitle: const Text(
              'الإصدار 2.3.0 — المنظومة الذكية لمراقبة الصرع',
            ),
          ),
          Gap.vSm,
          if (user != null) ...[
            Row(
              children: [
                Icon(
                  Icons.account_circle_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                Gap.hXs,
                Expanded(
                  child: Text(
                    DoctorTitleFormatter.formatWithRole(
                      user.name,
                      roleName,
                      role: user.role,
                      isArabic: l.isArabic,
                    ),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            Gap.vSm,
          ],
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: () => confirmSignOut(context, app),
              icon: const Icon(Icons.logout),
              label: Text(l.logout),
            ),
          ),
        ],
      ),
    );
  }
}
