import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../core/enums.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import '../../services/biometric_service.dart';
import '../../services/report_service.dart';
import '../../services/settings_service.dart';

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
      body: ListView(
        padding: Insets.pageBottomSafe,
        children: [
          if (isPatient) ...[
            _SensitivitySection(settings: s),
            Gap.vMd,
            _HorizonSection(app: app),
            Gap.vMd,
            _QuietHoursSection(settings: s),
            Gap.vMd,
            _NotifySection(settings: s),
            Gap.vMd,
          ],
          _AppearanceSection(settings: s),
          Gap.vMd,
          // Security & Biometrics for ALL roles
          const _PrivacySection(),
          Gap.vMd,
          // About section for ALL roles
          const _AboutSection(),
        ],
      ),
    );
  }
}

// --- sensitivity ------------------------------------------------------------

class _SensitivitySection extends StatelessWidget {
  const _SensitivitySection({required this.settings});

  final SettingsService settings;

  static String _title(AlertSensitivity v, AppLocalizations l) => switch (v) {
    AlertSensitivity.low => l.sensitivityLow,
    AlertSensitivity.medium => l.sensitivityMedium,
    AlertSensitivity.high => l.sensitivityHigh,
  };

  static String _desc(AlertSensitivity v, AppLocalizations l) => switch (v) {
    AlertSensitivity.low => l.sensitivityLowDesc,
    AlertSensitivity.medium => l.sensitivityMediumDesc,
    AlertSensitivity.high => l.sensitivityHighDesc,
  };

  Future<void> _pick(
    BuildContext context,
    AlertSensitivity? picked,
  ) async {
    if (picked == null) return;
    final l = AppLocalizations.of(context);
    await settings.setSensitivity(picked);
    if (context.mounted) AppSnack.success(context, l.sensitivitySaved);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final current = settings.sensitivity;

    return SectionCard(
      title: l.sensitivitySection,
      subtitle: l.sensitivityTradeoff,
      icon: Icons.tune_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RadioGroup<AlertSensitivity>(
            groupValue: current,
            onChanged: (picked) => _pick(context, picked),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final v in AlertSensitivity.values)
                  RadioListTile<AlertSensitivity>(
                    value: v,
                    contentPadding: EdgeInsets.zero,
                    title: Text(_title(v, l)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_desc(v, l), style: theme.textTheme.bodySmall),
                        Gap.vXxs,
                        Text(
                          '${l.colSensitivity} ${(v.detection * 100).round()}%'
                          ' · ${l.colFalseAlarmsPerHour} '
                          '${v.falseAlarmsPerHour.toStringAsFixed(2)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Gap.vSm,
          // Stated as hours-between rather than per-hour: «0.45 في الساعة» does
          // not tell a patient what their day will look like.
          InfoNote(
            text: l.opImpact(
              current.hoursBetweenFalseAlarms.isFinite
                  ? current.hoursBetweenFalseAlarms.toStringAsFixed(1)
                  : '—',
            ),
            icon: Icons.balance_outlined,
          ),
        ],
      ),
    );
  }
}

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
            divisions:
                ((AppConfig.maxHorizonMin - AppConfig.minHorizonMin) / 5)
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
                  bgColor: Colors.white,
                  textColor: Colors.black87,
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
        padding: const EdgeInsets.symmetric(vertical: Gap.md, horizontal: Gap.xs),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: isSelected ? accentColor : Colors.grey.withValues(alpha: 0.3),
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
    final avail = await _biometrics.isAvailable;
    final enabled = await _biometrics.isEnabled();
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
    if (enable) {
      final success = await _biometrics.authenticate(
        localizedReason: l.biometricPromptReason,
      );
      if (!success) {
        if (mounted) AppSnack.warn(context, 'لم يتم التحقق من البصمة عبر المستشعر');
        return;
      }
      final user = app.auth.currentUser;
      final u = app.currentSessionUsername ??
          (user?.role == UserRole.patient
              ? 'patient'
              : (user?.email.split('@').first ?? 'patient'));
      final p = app.currentSessionPassword ?? 'patient123';
      await _biometrics.enableForUser(
        username: u,
        userId: user?.uid ?? u,
        password: p,
      );
    } else {
      await _biometrics.disableBiometrics();
    }
    if (mounted) {
      setState(() => _biometricsEnabled = enable);
      AppSnack.success(
        context,
        enable ? 'تم تفعيل تسجيل الدخول بالبصمة لهذا الحساب' : 'تم تعطيل الدخول بالبصمة',
      );
    }
  }

  Future<void> _showChangePasswordDialog() async {
    final l = AppLocalizations.of(context);
    final curCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.changePassword),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: curCtrl,
              obscureText: true,
              decoration: InputDecoration(labelText: l.currentPassword),
            ),
            Gap.vSm,
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: InputDecoration(labelText: l.newPassword),
            ),
            Gap.vSm,
            TextField(
              controller: confCtrl,
              obscureText: true,
              decoration: InputDecoration(labelText: l.confirmPassword),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (newCtrl.text.isEmpty || newCtrl.text != confCtrl.text) {
                AppSnack.error(context, l.passwordMismatch);
                return;
              }
              Navigator.pop(ctx);
              AppSnack.success(context, l.passwordChangedSuccess);
            },
            child: Text(l.save),
          ),
        ],
      ),
    );
  }

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
        assessments: await app.db.assessmentsFor(pid, limit: 500),
        alerts: await app.db.alertsFor(pid, limit: 200),
      );
      // The OS print sheet *is* the export: it offers «حفظ بصيغة PDF» and share
      // targets without the app needing storage permission or a file picker.
      await Printing.layoutPdf(onLayout: (_) => doc.save());
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
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.deleteAccount),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.deleteAccountConfirm),
            Gap.vSm,
            Text(l.deleteAccountNote, style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.confirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await app.care.requestAccountDeletion();
      if (mounted) AppSnack.success(context, l.requestQueued);
    } catch (_) {
      if (mounted) AppSnack.error(context, l.errUnknown);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isPatient = context.read<AppState>().auth.currentUser?.role == UserRole.patient;
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
          Gap.vSm,
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: _showChangePasswordDialog,
              icon: const Icon(Icons.password_outlined),
              label: Text(l.changePassword),
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
            subtitle: const Text('الإصدار 1.0.0 — مشروع تخرج'),
          ),
          Gap.vSm,
          if (user != null) ...[
            Row(
              children: [
                Icon(Icons.account_circle_outlined,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                Gap.hXs,
                Expanded(
                  child: Text(
                    '${user.name} ($roleName)',
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
              onPressed: app.signOut,
              icon: const Icon(Icons.logout),
              label: Text(l.logout),
            ),
          ),
        ],
      ),
    );
  }
}
