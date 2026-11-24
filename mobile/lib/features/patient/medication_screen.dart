import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failure.dart';
import '../../core/enums.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../core/utils/external_actions.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../services/medication_service.dart';
import '../../widgets/app_drawer.dart';

/// §3.4 — medication adherence.
///
/// The screen is built around one idea: **the next dose is the only thing most
/// patients open this screen for.** So today's plan is first, the one-tap
/// «تم الأخذ» is the largest control on it, and the drug list — which changes
/// perhaps twice a year — is below.
///
/// Notes on the choices that are not obvious:
///
/// * **Adherence is shown for two windows, 7 and 30 days.** One number alone is
///   ambiguous: 60 % over a week is a bad week, 60 % over a month is a problem
///   the doctor needs to hear about. `l.adherenceNote` states that the figure is
///   self-reported, because it is, and a percentage that looks measured when it
///   is declared would be misread by everyone.
/// * **Pausing is not deleting.** A drug the doctor stopped should stop
///   generating reminders and stop counting against adherence, but its history
///   must survive — `MedicationService.setActive` does exactly that, while
///   `remove` also drops the logs. Both are offered; only one is destructive and
///   it asks first.
/// * **Sharing with the doctor copies text.** No route exists for pushing an
///   adherence report, and inventing one would be a promise the backend cannot
///   keep. The clipboard works offline, on every device, always.
/// * **Open gap: refill reminders.** §3.4 asks for «تنبيه قبل نفاد الدواء» and
///   `l.refillWarning` is already translated, but nothing in the data model
///   stores a supply count — `Medication` has name, dosage, schedule and times.
///   Guessing one would put a fabricated number in front of a patient, so the
///   feature is left out and recorded in `docs/frontend-implementation-ar.md` as
///   needing a `supplyCount` field on `Medication` plus the matching column.
class MedicationScreen extends StatefulWidget {
  const MedicationScreen({super.key, this.patientId});

  /// Optional so the screen can be a tab (`const MedicationScreen()`) that
  /// follows whichever patient is active, and also be pushed for a specific one.
  final String? patientId;

  @override
  State<MedicationScreen> createState() => _MedicationScreenState();
}

class _MedicationScreenState extends State<MedicationScreen> {
  bool _loading = true;
  bool _busy = false;
  _MedData? _data;
  Failure? _failure;

  MedicationService get _svc => context.read<AppState>().medication;

  String? get _pid =>
      widget.patientId ?? context.read<AppState>().activePatientId;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _load();
  }

  Future<void> _load() async {
    final pid = _pid;
    setState(() {
      _loading = true;
      _failure = null;
    });
    if (pid == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final app = context.read<AppState>();
      final owner = app.auth.currentUser;
      final origin = app.api.baseUrl;
      try {
        await _svc.synchronize(pid);
      } catch (_) {
        /* Local prescriptions remain readable offline. */
      }
      if (!mounted ||
          _pid != pid ||
          !AppUser.sameSessionOwner(owner, app.auth.currentUser) ||
          origin != app.api.baseUrl) {
        return;
      }
      final data = _MedData(
        meds: await _svc.forPatient(pid),
        schedule: await _svc.todaySchedule(pid),
        week: await _svc.adherence(pid),
        month: await _svc.adherence(pid, days: 30),
        missed: await _svc.missedDoses(pid),
      );
      if (!mounted ||
          _pid != pid ||
          !AppUser.sameSessionOwner(owner, app.auth.currentUser) ||
          origin != app.api.baseUrl) {
        return;
      }
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = Failure.from(e);
        _loading = false;
      });
    }
  }

  DateTime _todayAt(String hhmm) {
    final parts = hhmm.split(':');
    final now = DateTime.now();
    final h = int.tryParse(parts.first) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return DateTime(now.year, now.month, now.day, h, m);
  }

  Future<void> _guard(Future<void> Function() action, String okMessage) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await action();
      await _load();
      if (mounted) AppSnack.success(context, okMessage);
    } catch (_) {
      if (mounted) AppSnack.error(context, l.errUnknown);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _markTaken(ScheduleEntry e) async {
    final l = AppLocalizations.of(context);
    await _guard(
      () => _svc.markTaken(e.medication, scheduledFor: _todayAt(e.time)),
      l.doseTaken,
    );
  }

  Future<void> _addOrEdit({
    Medication? existing,
    String? initialName,
    String? initialDosage,
  }) async {
    final l = AppLocalizations.of(context);
    final pid = _pid;
    if (pid == null) return;
    final draft = await showModalBottomSheet<_MedDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MedSheet(
        existing: existing,
        initialName: initialName,
        initialDosage: initialDosage,
      ),
    );
    if (draft == null || !mounted) return;
    await _guard(() async {
      if (existing == null) {
        await _svc.add(
          patientId: pid,
          name: draft.name,
          dosage: draft.dosage,
          times: draft.times,
        );
      } else {
        await _svc.update(
          existing,
          name: draft.name,
          dosage: draft.dosage,
          times: draft.times,
        );
      }
    }, l.saved);
  }

  Future<void> _togglePause(Medication med) async {
    final l = AppLocalizations.of(context);
    await _guard(
      () => _svc.setActive(med, !med.active),
      med.active ? l.medPaused : l.saved,
    );
  }

  Future<void> _remove(Medication med) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.delete),
        // Names the drug and repeats the consequence. «هل أنت متأكد؟» alone does
        // not tell the patient they are about to lose their dose history too.
        content: Text('${med.name}\n\n${l.confirmDelete}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _guard(() => _svc.remove(med), l.deleted);
  }

  Future<void> _share(_MedData d) async {
    final l = AppLocalizations.of(context);
    final lines = <String>[
      l.medsTitle,
      '${l.adherenceWeek}: ${_pct(d.week)}',
      '${l.adherenceMonth}: ${_pct(d.month)}',
      '${l.missedDoses}: ${d.missed}',
      '',
      ...d.meds.map((m) {
        final bits = [
          m.name,
          if (m.dosage.isNotEmpty) m.dosage,
          if (m.times.isNotEmpty) m.times.join(' · '),
          if (!m.active) l.medPaused,
        ];
        return '- ${bits.join(' · ')}';
      }),
      '',
      l.adherenceNote,
    ];
    final ok = await ExternalActions.copy(lines.join('\n'));
    if (!mounted) return;
    ok
        ? AppSnack.success(context, l.copied)
        : AppSnack.error(context, l.exportFailed);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final pid = widget.patientId ?? app.activePatientId;

    if (pid == null) {
      return Scaffold(
        drawer: const AppDrawer(),
        appBar: AppBar(title: Text(l.medsTitle)),
        body: EmptyState(
          title: l.noPatientSelected,
          body: l.noLinkedPatientsBody,
          icon: Icons.person_search_outlined,
        ),
      );
    }

    final canPop = Navigator.canPop(context);
    final profile = app.auth.patientById(pid);
    final isOtherPatient =
        widget.patientId != null &&
        widget.patientId != app.auth.currentUser?.uid;
    final role = app.auth.currentUser?.role ?? UserRole.patient;
    final canManageMeds =
        app.auth.isDemoSession &&
        (role == UserRole.doctor || role == UserRole.admin);
    final canTakeDose = role == UserRole.patient;
    final canShareAdherence = role == UserRole.patient;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: const AppDrawer(),
      appBar: AppBar(
        backgroundColor: theme.appBarTheme.backgroundColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.medsTitle,
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
            if (isOtherPatient && profile != null)
              Text(
                'المريض: ${profile.name}',
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
          ],
        ),
        leading: canPop
            ? BackButton(color: theme.colorScheme.onSurface)
            : Builder(
                builder: (ctx) => IconButton(
                  tooltip: 'القائمة الجانبية',
                  icon: Icon(
                    Icons.menu_rounded,
                    color: theme.colorScheme.onSurface,
                  ),
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                ),
              ),
        actions: [
          if (canManageMeds)
            IconButton(
              tooltip: l.addMedication,
              onPressed: _busy ? null : () => _addOrEdit(),
              icon: Icon(
                Icons.add_circle_outline,
                color: theme.colorScheme.primary,
              ),
            ),
          IconButton(
            tooltip: l.refresh,
            onPressed: _loading ? null : _load,
            icon: Icon(
              Icons.refresh_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      floatingActionButton: canManageMeds
          ? FloatingActionButton.extended(
              heroTag: null,
              elevation: 4,
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              onPressed: _busy ? null : () => _addOrEdit(),
              icon: const Icon(Icons.add),
              label: Text(
                l.addMedication,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            )
          : null,
      body: AsyncView<_MedData>(
        loading: _loading,
        failure: _failure,
        value: _data,
        onRetry: _load,
        builder: (context, d) => RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: Insets.pageBottomSafe,
            children: [
              OfflineBanner(visible: !app.apiOnline),
              _AdherenceSection(
                data: d,
                onShare: canShareAdherence ? () => _share(d) : null,
              ),
              Gap.vMd,
              _TodaySection(
                schedule: d.schedule,
                enabled: !_busy && canTakeDose,
                canTakeDose: canTakeDose,
                onTaken: _markTaken,
              ),
              Gap.vMd,
              _MedListSection(
                meds: d.meds,
                enabled: !_busy && canManageMeds,
                canManage: canManageMeds,
                onEdit: (m) => _addOrEdit(existing: m),
                onTogglePause: _togglePause,
                onRemove: _remove,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _pct(double v) => '${(v * 100).round()}%';

/// Everything the screen renders, loaded together so the four states are driven
/// by one flag rather than five independent futures.
class _MedData {
  const _MedData({
    required this.meds,
    required this.schedule,
    required this.week,
    required this.month,
    required this.missed,
  });

  final List<Medication> meds;
  final List<ScheduleEntry> schedule;
  final double week;
  final double month;
  final int missed;
}

class _MedDraft {
  const _MedDraft({
    required this.name,
    required this.dosage,
    required this.times,
  });

  final String name;
  final String dosage;
  final List<String> times;
}

// ------------------------------------------------------------------ adherence

class _AdherenceSection extends StatelessWidget {
  const _AdherenceSection({required this.data, this.onShare});

  final _MedData data;
  final VoidCallback? onShare;

  /// §3.4's own boundary: 80 % is the line a doctor acts on, 50 % is the line
  /// where the model's own accuracy figures stop meaning much.
  static RiskView _view(double v) => v >= 0.8
      ? RiskView.safe
      : v >= 0.5
      ? RiskView.caution
      : RiskView.danger;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return SectionCard(
      title: l.adherenceWeek,
      icon: Icons.fact_check_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _Ring(
                  value: data.week,
                  label: l.adherenceWeek,
                  view: _view(data.week),
                ),
              ),
              Gap.hSm,
              Expanded(
                child: _Ring(
                  value: data.month,
                  label: l.adherenceMonth,
                  view: _view(data.month),
                ),
              ),
            ],
          ),
          Gap.vMd,
          LabeledValue(
            label: l.missedDoses,
            value: '${data.missed}',
            icon: Icons.remove_circle_outline,
          ),
          Gap.vSm,
          // The honest caveat, not a disclaimer buried in settings: this is what
          // the patient said they took, not what the body absorbed.
          InfoNote(
            text: l.adherenceNote,
            icon: Icons.info_outline,
            view: RiskView.unknown,
          ),
          if (onShare != null) ...[
            Gap.vSm,
            SizedBox(
              height: A11y.minTouchTarget,
              child: OutlinedButton.icon(
                onPressed: onShare,
                icon: const Icon(Icons.ios_share_outlined),
                label: Text(l.shareWithDoctor),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.value, required this.label, required this.view});

  final double value;
  final String label;
  final RiskView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = AppColors.of(context, view);

    return Container(
      padding: Insets.tile,
      decoration: BoxDecoration(
        color: tone.container,
        border: Border.all(color: tone.border),
        borderRadius: Radii.rMd,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // The ring is decoration; the number beside it is the content,
                // so the ring itself is hidden from a screen reader.
                ExcludeSemantics(
                  child: CircularProgressIndicator(
                    value: value.clamp(0.0, 1.0),
                    strokeWidth: 5,
                    backgroundColor: tone.border,
                    valueColor: AlwaysStoppedAnimation<Color>(tone.solid),
                  ),
                ),
                Text(
                  _pct(value),
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: tone.foreground,
                  ),
                ),
              ],
            ),
          ),
          Gap.hSm,
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: tone.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- today's plan

class _TodaySection extends StatelessWidget {
  const _TodaySection({
    required this.schedule,
    required this.enabled,
    this.canTakeDose = true,
    required this.onTaken,
  });

  final List<ScheduleEntry> schedule;
  final bool enabled;
  final bool canTakeDose;
  final ValueChanged<ScheduleEntry> onTaken;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final now = DateTime.now();
    final nowHhmm =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final remaining = schedule.where((e) => !e.taken).length;

    return SectionCard(
      title: l.todayPlan,
      icon: Icons.today_outlined,
      subtitle: schedule.isEmpty
          ? null
          : (remaining == 0 ? l.doseTaken : '$remaining'),
      child: schedule.isEmpty
          ? EmptyState(
              title: l.noDoseDue,
              body: l.emptyBody,
              icon: Icons.medication_liquid_outlined,
              compact: true,
            )
          : Column(
              children: [
                for (final e in schedule)
                  _DoseTile(
                    entry: e,
                    overdue: !e.taken && e.time.compareTo(nowHhmm) < 0,
                    enabled: enabled,
                    canTakeDose: canTakeDose,
                    onTaken: () => onTaken(e),
                  ),
              ],
            ),
    );
  }
}

class _DoseTile extends StatelessWidget {
  const _DoseTile({
    required this.entry,
    required this.overdue,
    required this.enabled,
    this.canTakeDose = true,
    required this.onTaken,
  });

  final ScheduleEntry entry;
  final bool overdue;
  final bool enabled;
  final bool canTakeDose;
  final VoidCallback onTaken;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final bool taken = entry.taken;
    final med = entry.medication;
    final dosage = med.dosage.isEmpty ? '' : ' · ${med.dosage}';

    final safe = AppColors.of(context, RiskView.safe);
    final caution = AppColors.of(context, RiskView.caution);
    final colors = Theme.of(context).colorScheme;
    final Color cardBg = taken
        ? safe.container
        : (overdue ? caution.container : colors.surface);
    final Color borderColor = taken
        ? safe.border
        : (overdue ? caution.border : colors.outlineVariant);
    final Color iconColor = taken
        ? safe.foreground
        : (overdue ? caution.foreground : colors.primary);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cardBg,
          border: Border.all(color: borderColor, width: 1.2),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                taken
                    ? Icons.check_circle_rounded
                    : (overdue
                          ? Icons.warning_amber_rounded
                          : Icons.medication_rounded),
                color: iconColor,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${med.name}$dosage',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    taken
                        ? '${l.takenAt} ${TimeAgo.clock(entry.log?.takenAt ?? DateTime.now(), l)}'
                        : '${l.dueAt} ${TimeAgo.formatHhmm12h(entry.time, isArabic: l.isArabic)}',
                    style: TextStyle(
                      color: taken
                          ? const Color(0xFF2E7D32)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (taken)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  l.doseTaken,
                  style: const TextStyle(
                    color: Color(0xFF2E7D32),
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              )
            else if (canTakeDose)
              SizedBox(
                height: 38,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0066FF),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: enabled ? onTaken : null,
                  icon: const Icon(Icons.check, size: 16),
                  label: Text(
                    l.takeDose,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
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

// ------------------------------------------------------------------ drug list

class _MedListSection extends StatelessWidget {
  const _MedListSection({
    required this.meds,
    required this.enabled,
    this.canManage = false,
    required this.onEdit,
    required this.onTogglePause,
    required this.onRemove,
  });

  final List<Medication> meds;
  final bool enabled;
  final bool canManage;
  final ValueChanged<Medication> onEdit;
  final ValueChanged<Medication> onTogglePause;
  final ValueChanged<Medication> onRemove;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return SectionCard(
      title: l.medsTitle,
      icon: Icons.medication_outlined,
      trailing: Text(
        '${meds.length}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      child: meds.isEmpty
          ? EmptyState(
              title: l.noMedsYet,
              body: l.emptyBody,
              icon: Icons.medication_outlined,
              compact: true,
            )
          : Column(
              children: [
                for (final m in meds)
                  _MedTile(
                    med: m,
                    enabled: enabled,
                    canManage: canManage,
                    onEdit: () => onEdit(m),
                    onTogglePause: () => onTogglePause(m),
                    onRemove: () => onRemove(m),
                  ),
              ],
            ),
    );
  }
}

class _MedTile extends StatelessWidget {
  const _MedTile({
    required this.med,
    required this.enabled,
    this.canManage = false,
    required this.onEdit,
    required this.onTogglePause,
    required this.onRemove,
  });

  final Medication med;
  final bool enabled;
  final bool canManage;
  final VoidCallback onEdit;
  final VoidCallback onTogglePause;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final subtitle = [
      if (med.dosage.isNotEmpty) med.dosage,
      scheduleLabel(med.schedule, l),
      if (medicationContextLabel(med, l).isNotEmpty)
        medicationContextLabel(med, l),
      if (med.prescriptionId != null && med.times.isEmpty) l.notSet,
      if (med.times.isNotEmpty)
        med.times
            .map((t) => TimeAgo.formatHhmm12h(t, isArabic: l.isArabic))
            .join(' · '),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            med.name,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              // A paused drug is struck through, not hidden. It
                              // is still part of the patient's history and they
                              // may be asked about it.
                              decoration: med.active
                                  ? null
                                  : TextDecoration.lineThrough,
                            ),
                          ),
                        ),
                        if (!med.active) ...[
                          Gap.hXs,
                          Text(
                            l.medPaused,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (canManage) ...[
                IconButton(
                  tooltip: l.edit,
                  onPressed: enabled ? onEdit : null,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: med.active ? l.pauseMed : l.resumeMed,
                  onPressed: enabled ? onTogglePause : null,
                  icon: Icon(
                    med.active
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                  ),
                ),
                IconButton(
                  tooltip: l.delete,
                  onPressed: enabled ? onRemove : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ],
          ),
          const Divider(height: Gap.md),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- add / edit

class _MedSheet extends StatefulWidget {
  const _MedSheet({this.existing, this.initialName, this.initialDosage});

  final Medication? existing;
  final String? initialName;
  final String? initialDosage;

  @override
  State<_MedSheet> createState() => _MedSheetState();
}

class _MedSheetState extends State<_MedSheet> {
  late final TextEditingController _name;
  late final TextEditingController _dosage;
  late List<String> _times;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: widget.existing?.name ?? widget.initialName ?? '',
    );
    _dosage = TextEditingController(
      text: widget.existing?.dosage ?? widget.initialDosage ?? '',
    );
    // Two defaults for a new drug, matching `MedicationService.add`. Most
    // anti-epileptics are twice daily, and a plan with no times generates no
    // reminders at all — the one outcome this screen exists to prevent.
    _times = List<String>.from(
      widget.existing?.times ?? const ['08:00', '20:00'],
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _dosage.dispose();
    super.dispose();
  }

  Future<void> _addTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked == null) return;
    final hhmm =
        '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    if (_times.contains(hhmm)) return;
    setState(() {
      _times = [..._times, hhmm]..sort();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: Gap.lg + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null ? l.addMedication : l.edit,
              style: theme.textTheme.titleMedium,
            ),
            Gap.vMd,
            TextField(
              controller: _name,
              autofocus: widget.existing == null,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: l.medName),
              onChanged: (_) => setState(() {}),
            ),
            Gap.vSm,
            TextField(
              controller: _dosage,
              decoration: InputDecoration(
                labelText: l.dosage,
                // An example, not a rule: dosages are written a dozen ways and
                // rejecting any of them would be worse than accepting all.
                hintText: '500mg',
              ),
            ),
            Gap.vMd,
            Text(l.doseTimes, style: theme.textTheme.labelLarge),
            Gap.vXs,
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final t in _times)
                  InputChip(
                    label: Text(t),
                    onDeleted: () => setState(() {
                      _times = _times.where((x) => x != t).toList();
                    }),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add_alarm_outlined, size: 18),
                  label: Text(l.add),
                  onPressed: _addTime,
                ),
              ],
            ),
            if (_times.isEmpty) ...[
              Gap.vSm,
              // Allowed, but never silently: a drug with no times still belongs
              // in the list ("as needed"), it just cannot remind anyone.
              InfoNote(
                text: l.noDoseDue,
                icon: Icons.notifications_off_outlined,
                view: RiskView.caution,
              ),
            ],
            Gap.vLg,
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.cancel),
                  ),
                ),
                Gap.hSm,
                Expanded(
                  child: SizedBox(
                    height: A11y.minTouchTarget,
                    child: FilledButton(
                      onPressed: _name.text.trim().isEmpty
                          ? null
                          : () => Navigator.pop(
                              context,
                              _MedDraft(
                                name: _name.text,
                                dosage: _dosage.text,
                                times: _times,
                              ),
                            ),
                      child: Text(l.save),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
