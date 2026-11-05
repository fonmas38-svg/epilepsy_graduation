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
            _FamilyCaregiversSection(app: app),
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

// --- family caregivers ------------------------------------------------------

class _FamilyCaregiversSection extends StatefulWidget {
  const _FamilyCaregiversSection({required this.app});

  final AppState app;

  @override
  State<_FamilyCaregiversSection> createState() => _FamilyCaregiversSectionState();
}

class _FamilyCaregiversSectionState extends State<_FamilyCaregiversSection> {
  bool _loading = true;
  bool _busy = false;
  List<Map<String, dynamic>> _caregivers = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await widget.app.api.patientGetCaregivers();
      if (mounted) {
        setState(() {
          _caregivers = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _showAddDialog() async {
    final nameCtrl = TextEditingController();
    final usernameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final relationCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.person_add_alt_1_outlined),
            Gap.hSm,
            Text('إضافة فرد أسرة جديد'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'الاسم الكامل *',
                  hintText: 'مثال: سارة أحمد',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
              Gap.vSm,
              TextField(
                controller: usernameCtrl,
                decoration: const InputDecoration(
                  labelText: 'اسم المستخدم (لتسجيل الدخول) *',
                  hintText: 'مثال: sarah_care',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
              ),
              Gap.vSm,
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'رقم الهاتف',
                  hintText: '+966500000000',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
              ),
              Gap.vSm,
              TextField(
                controller: relationCtrl,
                decoration: const InputDecoration(
                  labelText: 'صلة القرابة',
                  hintText: 'مثال: أم / أب / أخ / زوجة',
                  prefixIcon: Icon(Icons.family_restroom_outlined),
                ),
              ),
              Gap.vSm,
              TextField(
                controller: passwordCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'كلمة المرور (اختياري - 6 خانات على الأقل)',
                  hintText: 'اتركه فارغاً للتوليد التلقائي',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty || usernameCtrl.text.trim().isEmpty) {
                AppSnack.warn(context, 'يرجى إدخال الاسم واسم المستخدم');
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('إضافة'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final res = await widget.app.api.patientAddCaregiver(
        name: nameCtrl.text.trim(),
        username: usernameCtrl.text.trim(),
        phone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
        relation: relationCtrl.text.trim().isEmpty ? null : relationCtrl.text.trim(),
        password: passwordCtrl.text.trim().isEmpty ? null : passwordCtrl.text.trim(),
      );
      final genPass = res['generatedPassword'];
      if (mounted) {
        if (genPass != null) {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('تم إنشاء الحساب بنجاح'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('اسم المستخدم: ${usernameCtrl.text.trim()}'),
                  Gap.vXs,
                  Text('كلمة المرور المُنشأة: $genPass',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Gap.vSm,
                  const Text('احتفظ بكلمة المرور لتسليمها لفرد الأسرة.'),
                ],
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('تم'),
                ),
              ],
            ),
          );
        } else {
          AppSnack.success(context, 'تمت إضافة فرد الأسرة بنجاح');
        }
        _load();
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showEditDialog(Map<String, dynamic> member) async {
    final nameCtrl = TextEditingController(text: member['name']?.toString() ?? '');
    final phoneCtrl = TextEditingController(text: member['phone']?.toString() ?? '');
    final relationCtrl = TextEditingController(text: member['relation']?.toString() ?? '');
    final memberId = member['id']?.toString() ?? '';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.edit_outlined),
            Gap.hSm,
            Text('تعديل بيانات فرد الأسرة'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'الاسم الكامل *',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
              Gap.vSm,
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'رقم الهاتف',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
              ),
              Gap.vSm,
              TextField(
                controller: relationCtrl,
                decoration: const InputDecoration(
                  labelText: 'صلة القرابة',
                  prefixIcon: Icon(Icons.family_restroom_outlined),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty) {
                AppSnack.warn(context, 'الاسم مطلوب');
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('حفظ التعديلات'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.app.api.patientUpdateCaregiver(
        caregiverId: memberId,
        name: nameCtrl.text.trim(),
        phone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
        relation: relationCtrl.text.trim().isEmpty ? null : relationCtrl.text.trim(),
      );
      if (mounted) {
        AppSnack.success(context, 'تم تحديث بيانات فرد الأسرة بنجاح');
        _load();
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleDisabled(Map<String, dynamic> member) async {
    final memberId = member['id']?.toString() ?? '';
    final isCurrentlyDisabled = member['disabled'] == true;
    final name = member['name']?.toString() ?? 'فرد الأسرة';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isCurrentlyDisabled ? 'إعادة تفعيل الحساب' : 'تعطيل الحساب مؤقتاً'),
        content: Text(
          isCurrentlyDisabled
              ? 'هل تريد إعادة تفعيل حساب «$name»؟ سيتمكن من تسجيل الدخول وتلقي إشعارات الطوارئ مجدداً.'
              : 'هل تريد تعطيل حساب «$name»؟ لن يتلقى إشعارات الطوارئ ولن يتمكن من الدخول حتى تعيد تفعيله.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: isCurrentlyDisabled
                ? null
                : FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isCurrentlyDisabled ? 'تفعيل' : 'تعطيل'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.app.api.patientSetCaregiverDisabled(
        memberId,
        disabled: !isCurrentlyDisabled,
      );
      if (mounted) {
        AppSnack.success(
          context,
          isCurrentlyDisabled ? 'تمت إعادة تفعيل الحساب' : 'تم تعطيل الحساب بنجاح',
        );
        _load();
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'أفراد الأسرة والمرافقين',
      subtitle: 'إدارة أفراد العائلة الذين يتلقون إشعارات الطوارئ عند حدوث نوبة',
      icon: Icons.family_restroom_outlined,
      trailing: IconButton.filledTonal(
        icon: const Icon(Icons.person_add_outlined),
        tooltip: 'إضافة فرد أسرة جديد',
        onPressed: _busy ? null : _showAddDialog,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(Gap.md),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_caregivers.isEmpty)
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.group_off_outlined,
                    size: 40,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  Gap.vSm,
                  Text(
                    'لا يوجد أفراد أسرة مسجلين حالياً',
                    style: theme.textTheme.titleSmall,
                  ),
                  Gap.vXs,
                  Text(
                    'أضف أفراد عائلتك أو المرافقين ليتلقوا تنبيهات فورية وموقعك الجغرافي عند الاشتباه بحدوث نوبة.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Gap.vMd,
                  FilledButton.icon(
                    onPressed: _showAddDialog,
                    icon: const Icon(Icons.person_add_outlined),
                    label: const Text('إضافة فرد أسرة'),
                  ),
                ],
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _caregivers.length,
              separatorBuilder: (_, _) => Gap.vSm,
              itemBuilder: (context, idx) {
                final cg = _caregivers[idx];
                final name = cg['name']?.toString() ?? 'بدون اسم';
                final username = cg['username']?.toString() ?? '';
                final phone = cg['phone']?.toString();
                final relation = cg['relation']?.toString();
                final isDisabled = cg['disabled'] == true;

                return Container(
                  padding: const EdgeInsets.all(Gap.sm),
                  decoration: BoxDecoration(
                    color: isDisabled
                        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4)
                        : theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDisabled
                          ? theme.colorScheme.error.withValues(alpha: 0.3)
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: isDisabled
                                ? theme.colorScheme.errorContainer
                                : theme.colorScheme.primaryContainer,
                            foregroundColor: isDisabled
                                ? theme.colorScheme.onErrorContainer
                                : theme.colorScheme.onPrimaryContainer,
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '؟',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          Gap.hSm,
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      name,
                                      style: theme.textTheme.titleSmall?.copyWith(
                                        decoration: isDisabled ? TextDecoration.lineThrough : null,
                                      ),
                                    ),
                                    if (relation != null && relation.isNotEmpty) ...[
                                      Gap.hXs,
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.secondaryContainer,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          relation,
                                          style: theme.textTheme.labelSmall?.copyWith(
                                            color: theme.colorScheme.onSecondaryContainer,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                Gap.vXs,
                                Row(
                                  children: [
                                    Icon(
                                      Icons.alternate_email,
                                      size: 14,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 2),
                                    Text(
                                      username,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    if (phone != null && phone.isNotEmpty) ...[
                                      Gap.hSm,
                                      Icon(
                                        Icons.phone_outlined,
                                        size: 14,
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 2),
                                      Text(
                                        phone,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: isDisabled
                                  ? theme.colorScheme.errorContainer
                                  : const Color(0xFFE8F5E9),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isDisabled ? Icons.block : Icons.check_circle_outline,
                                  size: 13,
                                  color: isDisabled
                                      ? theme.colorScheme.error
                                      : const Color(0xFF2E7D32),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  isDisabled ? 'معطّل' : 'نشط',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: isDisabled
                                        ? theme.colorScheme.error
                                        : const Color(0xFF2E7D32),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Gap.vSm,
                      const Divider(height: 1),
                      Gap.vXs,
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton.icon(
                            onPressed: _busy ? null : () => _showEditDialog(cg),
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            label: const Text('تعديل'),
                          ),
                          Gap.hSm,
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: isDisabled
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.error,
                            ),
                            onPressed: _busy ? null : () => _toggleDisabled(cg),
                            icon: Icon(
                              isDisabled ? Icons.check_circle_outline : Icons.block_outlined,
                              size: 16,
                            ),
                            label: Text(isDisabled ? 'إعادة تفعيل' : 'تعطيل الحساب'),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
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
    final app = context.read<AppState>();
    final user = app.auth.currentUser;
    final u = app.currentSessionUsername ??
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
    final u = app.currentSessionUsername ??
        (user?.role == UserRole.patient
            ? 'patient'
            : (user?.email.split('@').first ?? 'user'));

    if (enable) {
      final success = await _biometrics.authenticate(
        localizedReason: l.biometricPromptReason,
      );
      if (!success) {
        if (mounted) AppSnack.warn(context, 'لم يتم التحقق من البصمة عبر المستشعر');
        return;
      }
      final token = await app.api.tokens.bearer();
      if (token == null || user == null || app.auth.isDemoSession) {
        if (mounted) AppSnack.warn(context, l.signIn);
        return;
      }
      final enabled = await _biometrics.enableForUser(
        username: u, userId: user.uid, token: token,
        role: user.role.name, baseUrl: app.api.baseUrl,
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
      AppSnack.success(
        context,
        enable ? 'تم تفعيل تسجيل الدخول بالبصمة لحساب «$u»' : 'تم تعطيل الدخول بالبصمة لحساب «$u»',
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
            subtitle: const Text('الإصدار 2.3.0 — المنظومة الذكية لمراقبة الصرع'),
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
