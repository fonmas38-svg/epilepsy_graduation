import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../core/errors/failure.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/risk_indicator.dart';
import '../../core/ui/states.dart';
import '../../core/utils/external_actions.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/care_models.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../services/report_service.dart';
import '../../widgets/signal_chart.dart';
import '../caregiver/alert_response_screen.dart'
    show seizureDurationLabel, seizureTypeLabel;
import '../shared/alerts_list.dart';
import 'adjudication_screen.dart' show verdictIcon, verdictLabel, verdictView;

/// §5.2 — one patient, everything the treating doctor needs, in the order a
/// consultation actually goes.
///
/// The order is deliberate and is the main design decision on this screen:
///
/// 1. **Summary** — «كيف حال هذا المريض؟» answered before any scrolling.
/// 2. **Timeline** — what happened, all event kinds merged into one column.
///    Alerts, documented seizures, verdicts and forecasts interleaved, because a
///    doctor reads them against each other; four separate lists would force them
///    to do the merging by eye.
/// 3. **Signal window** — the raw evidence behind the last assessment.
/// 4. **Analytics** — how the system has performed *for this patient*.
/// 5. **Clinical notes** — the doctor's own record.
/// 6. **Per-patient settings** — the operating point, changed only after all of
///    the above has been read.
/// 7. **Reports** — the export, last because it is the exit.
///
/// Three constraints worth stating out loud:
///
/// * **Everything is read from SQLite, not the network.** A ward round happens
///   wherever the patient is, and that is rarely where the Wi-Fi is. The one
///   exception is the operating point, and it is marked as such.
/// * **Changing the operating point needs a connection.**
///   `CareService.setThreshold` is network-only by design — a sensitivity that
///   silently sat in an outbox would leave the doctor and the device disagreeing
///   about when to alert. So the button is disabled offline instead of lying.
/// * **Nothing here retrains the model.** The analytics are read-outs of past
///   behaviour; `l.modelPerformance` says so on screen.
class PatientFileScreen extends StatefulWidget {
  const PatientFileScreen({super.key, this.args});

  final PatientRouteArgs? args;

  @override
  State<PatientFileScreen> createState() => _PatientFileScreenState();
}

class _PatientFileScreenState extends State<PatientFileScreen> {
  final _reports = ReportService();

  bool _loading = true;
  bool _busy = false;
  _FileData? _data;
  Failure? _failure;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final pid = widget.args?.patientId ?? app.activePatientId;
    setState(() {
      _loading = true;
      _failure = null;
    });
    if (pid == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      // A doctor moves between patients, so the care service is rarely already
      // pointed at this one. Without this, notes and consents below would be
      // about whoever was open last.
      if (app.care.patientId != pid) {
        await app.care.loadFor(pid);
      }
      final db = app.db;
      final readings = await db.recentReadings(pid, limit: 1);
      final data = _FileData(
        patientId: pid,
        profile: app.auth.patientById(pid),
        assessments: await db.assessmentsFor(pid, limit: 200),
        alerts: await db.alertsFor(pid, limit: 200),
        seizures: await db.seizureLogsFor(pid, limit: 200),
        events: await db.predictionEventsFor(pid, limit: 200),
        adjudications: await db.adjudicationsFor(pid, limit: 200),
        notes: await app.care.clinicalNotesFor(pid),
        reading: readings.isEmpty ? null : readings.first,
        adherence: await app.medication.adherence(pid),
        activeMeds: (await app.medication.forPatient(
          pid,
          activeOnly: true,
        )).length,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
      await _logAccess(app);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = Failure.from(e);
        _loading = false;
      });
    }
  }

  /// §4.3 promises the patient a log of who looked at their file. Opening it is
  /// the event, so it is recorded here rather than behind a button.
  ///
  /// Local-only for now: `CareService.recordAccess` has no backend route yet, so
  /// a read on the doctor's device does not reach the patient's phone. Recorded
  /// as an open gap in `docs/frontend-implementation-ar.md`.
  Future<void> _logAccess(AppState app) async {
    try {
      await app.care.recordAccess(
        'viewed_history',
        actorName: app.auth.currentUser?.name ?? '',
      );
    } catch (_) {
      // Never the reason a doctor cannot read a file.
    }
  }

  Future<void> _addNote(_FileData d) async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _NoteSheet(),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await app.care.addClinicalNote(
        patientId: d.patientId,
        text: text,
        doctorId: app.auth.currentUser?.uid ?? '',
      );
      final notes = await app.care.clinicalNotesFor(d.patientId);
      if (!mounted) return;
      setState(() {
        _data = d.withNotes(notes);
        _busy = false;
      });
      AppSnack.success(
        context,
        app.apiOnline ? l.noteSaved : l.savedLocallyWillSync,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnack.error(context, l.errUnknown);
    }
  }

  Future<void> _applyPoint(_FileData d, AlertSensitivity point) async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await app.care.setThreshold(
        patientId: d.patientId,
        preictalThreshold: point.preictalThreshold,
        profile: point.value,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnack.success(context, l.thresholdSaved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      // The one write on this screen that cannot be queued, so the reason it
      // failed matters: «لا يوجد اتصال» tells the doctor to try again on the
      // ward Wi-Fi, a generic error tells them nothing.
      AppSnack.error(context, Failure.from(e).message(l));
    }
  }

  Future<void> _exportPdf(_FileData d) async {
    final l = AppLocalizations.of(context);
    final profile = d.profile;
    if (profile == null) return;
    setState(() => _busy = true);
    try {
      final doc = await _reports.toPdf(
        patient: profile,
        assessments: d.assessments,
        alerts: d.alerts,
      );
      await Printing.layoutPdf(onLayout: (_) => doc.save());
      if (mounted) AppSnack.success(context, l.reportReady);
    } catch (_) {
      if (mounted) AppSnack.error(context, l.exportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportCsv(_FileData d) async {
    final l = AppLocalizations.of(context);
    final profile = d.profile;
    if (profile == null) return;
    setState(() => _busy = true);
    try {
      final csv = _reports.toCsv(
        patient: profile,
        assessments: d.assessments,
        alerts: d.alerts,
      );
      // Same reasoning as §3.3: no file picker is wired and a share sheet needs
      // a plugin that may not be there, but the clipboard always works.
      final ok = await ExternalActions.copy(csv);
      if (!mounted) return;
      ok
          ? AppSnack.success(context, l.copied)
          : AppSnack.error(context, l.exportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final pid = widget.args?.patientId ?? app.activePatientId;

    if (pid == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l.patientFile)),
        body: EmptyState(
          title: l.noPatientSelected,
          body: l.noLinkedPatientsBody,
          icon: Icons.person_search_outlined,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_data?.profile?.name ?? l.patientFile),
        actions: [
          IconButton(
            tooltip: 'توجيهات ورسائل المريض',
            onPressed: () => Navigator.pushNamed(
              context,
              Routes.messages,
              arguments: PatientRouteArgs(
                patientId: pid,
                patientName: _data?.profile?.name,
              ),
            ),
            icon: const Icon(Icons.chat_bubble_outline),
          ),
          IconButton(
            tooltip: 'التقارير الطبية وتصدير Excel',
            onPressed: () => Navigator.pushNamed(
              context,
              Routes.reports,
              arguments: PatientRouteArgs(
                patientId: pid,
                patientName: _data?.profile?.name,
              ),
            ),
            icon: const Icon(Icons.table_chart_outlined),
          ),
          IconButton(
            tooltip: l.adjudicationTitle,
            onPressed: () =>
                Navigator.pushNamed(context, Routes.doctorAdjudication),
            icon: const Icon(Icons.gavel_outlined),
          ),
          IconButton(
            tooltip: l.refresh,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AsyncView<_FileData>(
        loading: _loading,
        failure: _failure,
        value: _data,
        onRetry: _load,
        emptyTitle: l.emptyTitle,
        emptyBody: l.emptyBody,
        builder: (context, d) => RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: Insets.pageBottomSafe,
            children: [
              OfflineBanner(
                visible: !app.apiOnline,
                lastUpdateLabel: TimeAgo.since(app.care.lastSyncedAt, l),
                pendingCount: app.care.pendingCount,
              ),
              _SummarySection(data: d),
              Gap.vMd,
              _TimelineSection(data: d),
              Gap.vMd,
              _SignalSection(reading: d.reading),
              Gap.vMd,
              _AnalyticsSection(data: d),
              Gap.vMd,
              _NotesSection(
                notes: d.notes,
                enabled: !_busy,
                onAdd: () => _addNote(d),
              ),
              Gap.vMd,
              _OperatingPointSection(
                current: app.settings.sensitivity,
                online: app.apiOnline,
                enabled: !_busy,
                onApply: (p) => _applyPoint(d, p),
              ),
              Gap.vMd,
              _ReportsSection(
                enabled: !_busy && d.profile != null,
                onPdf: () => _exportPdf(d),
                onCsv: () => _exportCsv(d),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------- data

class _FileData {
  const _FileData({
    required this.patientId,
    required this.profile,
    required this.assessments,
    required this.alerts,
    required this.seizures,
    required this.events,
    required this.adjudications,
    required this.notes,
    required this.reading,
    required this.adherence,
    required this.activeMeds,
  });

  final String patientId;
  final PatientProfile? profile;
  final List<RiskAssessment> assessments;
  final List<AlertItem> alerts;
  final List<SeizureLog> seizures;
  final List<PredictionEvent> events;
  final List<Adjudication> adjudications;
  final List<ClinicalNote> notes;

  /// The newest reading, for the signal window. One is enough: this section
  /// shows the evidence behind the last assessment, not a scrolling monitor.
  final VitalReading? reading;

  final double adherence;
  final int activeMeds;

  /// Notes change on this screen; nothing else does. Rebuilding just that list
  /// avoids a full reload — and a full reload would scroll the doctor back to
  /// the top of a long file for the sake of one line of text.
  _FileData withNotes(List<ClinicalNote> next) => _FileData(
    patientId: patientId,
    profile: profile,
    assessments: assessments,
    alerts: alerts,
    seizures: seizures,
    events: events,
    adjudications: adjudications,
    notes: next,
    reading: reading,
    adherence: adherence,
    activeMeds: activeMeds,
  );

  int get alerts7d {
    final since = DateTime.now().subtract(const Duration(days: 7));
    return alerts.where((a) => a.timestamp.isAfter(since)).length;
  }

  /// The most recent assessment wins over `profile.currentStatus`: the profile
  /// is refreshed by a sync, the assessment by the device.
  RiskLabel? get latestLabel =>
      assessments.isNotEmpty ? assessments.first.label : profile?.currentStatus;

  DateTime? get observedAt =>
      assessments.isNotEmpty ? assessments.first.timestamp : profile?.lastUpdated;
}

/// One row of the merged timeline. Built from four different sources, so the
/// shared shape is what makes them sortable against each other.
class _Event {
  const _Event({
    required this.at,
    required this.title,
    required this.icon,
    required this.view,
    this.subtitle = '',
    this.pending = false,
  });

  final DateTime at;
  final String title;
  final String subtitle;
  final IconData icon;
  final RiskView view;
  final bool pending;
}

String _pct(double v) => '${(v * 100).round()}%';

// ------------------------------------------------------------------ sections

class _SummarySection extends StatelessWidget {
  const _SummarySection({required this.data});

  final _FileData data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final d = data;
    final view = RiskViewX.resolve(
      label: d.latestLabel,
      observedAt: d.observedAt,
      dataAvailable: d.assessments.isNotEmpty || d.profile != null,
    );

    return SectionCard(
      title: l.summarySection,
      icon: Icons.badge_outlined,
      subtitle: d.profile?.patientId ?? d.patientId,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RiskGauge(
            view: view,
            freshnessLabel: TimeAgo.since(d.observedAt, l),
          ),
          Gap.vSm,
          RiskStrip(view: view),
          Gap.vMd,
          LabeledValue(
            label: l.diagnosis,
            value: d.profile?.diagnosis ?? l.notSet,
            icon: Icons.medical_information_outlined,
          ),
          LabeledValue(
            label: l.lastVisit,
            value: TimeAgo.since(d.observedAt, l),
            icon: Icons.schedule_outlined,
          ),
          LabeledValue(
            label: l.medsTitle,
            value: d.activeMeds == 0 ? l.noMedsYet : '${d.activeMeds}',
            icon: Icons.medication_outlined,
          ),
          Gap.vMd,
          // Four numbers, because a summary that needs scrolling is not one.
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: l.alerts7d,
                  value: '${d.alerts7d}',
                  view: d.alerts7d == 0 ? RiskView.safe : RiskView.caution,
                ),
              ),
              Gap.hSm,
              Expanded(
                child: _Stat(
                  label: l.seizureHistory,
                  value: '${d.seizures.length}',
                  view: d.seizures.isEmpty ? RiskView.safe : RiskView.danger,
                ),
              ),
            ],
          ),
          Gap.vSm,
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: l.adherenceShort,
                  value: _pct(d.adherence),
                  // §3.4's own boundary: below 80 % the doctor should be looking
                  // at the medication list, not at the model.
                  view: d.adherence >= 0.8 ? RiskView.safe : RiskView.caution,
                ),
              ),
              Gap.hSm,
              Expanded(
                child: _Stat(
                  label: l.totalAlerts,
                  value: '${d.alerts.length}',
                  view: RiskView.unknown,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.view});

  final String label;
  final String value;
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: tone.foreground,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: tone.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineSection extends StatelessWidget {
  const _TimelineSection({required this.data});

  final _FileData data;

  /// The merge. Kept in one place so every kind of event is dated the same way
  /// and nothing can drift out of order.
  List<_Event> _events(AppLocalizations l) {
    final out = <_Event>[];

    for (final a in data.alerts) {
      final s = alertSeverity(a.severity, l);
      out.add(
        _Event(
          at: a.timestamp,
          title: s.label,
          subtitle: a.message,
          icon: Icons.notifications_active_outlined,
          view: s.view,
        ),
      );
    }
    for (final s in data.seizures) {
      out.add(
        _Event(
          at: s.occurredAt,
          title: seizureTypeLabel(s.type, l),
          subtitle: [
            seizureDurationLabel(s.durationSeconds, l),
            if (s.notes.isNotEmpty) s.notes,
          ].join(' · '),
          icon: Icons.bolt_outlined,
          view: RiskView.danger,
          pending: !s.synced,
        ),
      );
    }
    for (final a in data.adjudications) {
      out.add(
        _Event(
          at: a.decidedAt,
          title: verdictLabel(a.verdict, l),
          subtitle: a.notes,
          icon: verdictIcon(a.verdict),
          view: verdictView(a.verdict),
          pending: !a.synced,
        ),
      );
    }
    for (final e in data.events) {
      out.add(
        _Event(
          at: e.firedAt,
          title: '${l.preictalProb} ${_pct(e.preictalProb)}',
          subtitle: e.leadTimeMin == null
              ? ''
              : '${l.leadTime}: ${e.leadTimeMin!.toStringAsFixed(0)} ${l.minutesUnit}',
          icon: Icons.timeline_outlined,
          // A forecast is not a claim about the patient right now, so the band
          // colour is read straight off the probability rather than resolved.
          view: e.preictalProb >= 0.6
              ? RiskView.danger
              : e.preictalProb >= 0.3
              ? RiskView.caution
              : RiskView.safe,
        ),
      );
    }

    out.sort((x, y) => y.at.compareTo(x.at));
    // Capped on purpose. A file with two hundred rows is a file nobody reads to
    // the end, and §3.3's history screen is where the full record lives.
    return out.length > 40 ? out.sublist(0, 40) : out;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final events = _events(l);

    return SectionCard(
      title: l.timelineSection,
      icon: Icons.history_outlined,
      trailing: Text(
        '${events.length}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      child: events.isEmpty
          ? EmptyState(
              title: l.noAlerts,
              body: l.emptyBody,
              icon: Icons.event_note_outlined,
              compact: true,
            )
          : Column(
              children: [for (final e in events) _EventTile(event: e)],
            ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final _Event event;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tone = AppColors.of(context, event.view);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(event.icon, size: 20, color: tone.foreground),
          Gap.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (event.subtitle.isNotEmpty)
                  Text(
                    event.subtitle,
                    style: theme.textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                Text(
                  [
                    TimeAgo.stamp(event.at),
                    if (event.pending) l.pendingSync,
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SignalSection extends StatelessWidget {
  const _SignalSection({required this.reading});

  final VitalReading? reading;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final r = reading;
    final b = Theme.of(context).brightness;

    return SectionCard(
      title: l.signalWindowSection,
      icon: Icons.show_chart_outlined,
      subtitle: r == null ? null : TimeAgo.stamp(r.timestamp),
      child: r == null
          ? EmptyState(
              title: l.chartNoData,
              body: l.emptyBody,
              icon: Icons.sensors_off_outlined,
              compact: true,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SignalChart(
                  title: l.driverEeg,
                  values: r.eeg,
                  color: AppColors.signalEeg(b),
                ),
                Gap.vSm,
                SignalChart(
                  title: l.driverEcg,
                  values: r.ecg,
                  color: AppColors.signalEcg(b),
                ),
                Gap.vSm,
                SignalChart(
                  title: l.driverMotion,
                  values: r.motion,
                  color: AppColors.signalMotion(b),
                ),
                Gap.vSm,
                LabeledValue(
                  label: l.driverHr,
                  value: r.hr <= 0
                      ? l.notSet
                      : '${r.hr.toStringAsFixed(0)} bpm',
                  icon: Icons.favorite_outline,
                ),
              ],
            ),
    );
  }
}

class _AnalyticsSection extends StatelessWidget {
  const _AnalyticsSection({required this.data});

  final _FileData data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final events = data.events;

    // Lead time is averaged only over the events that carry one. Counting a
    // null as a zero would drag the average down and make the system look worse
    // than it is; excluding them says «من بين N تنبيهاً لها زمن استباق».
    final withLead = events.where((e) => e.leadTimeMin != null).toList();
    final avgLead = withLead.isEmpty
        ? null
        : withLead.map((e) => e.leadTimeMin!).reduce((a, b) => a + b) /
              withLead.length;

    // Only events the patient or a clinician actually judged count towards the
    // false-alarm rate. An unresolved forecast is not evidence either way.
    final decided = events
        .where(
          (e) =>
              e.outcome == 'cancelled_false_alarm' ||
              e.outcome == 'onset_confirmed',
        )
        .toList();
    final falseAlarms = decided
        .where((e) => e.outcome == 'cancelled_false_alarm')
        .length;

    return SectionCard(
      title: l.analyticsSection,
      icon: Icons.insights_outlined,
      subtitle: l.modelPerformance,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledValue(
            label: l.totalAlerts,
            value: '${events.length}',
            icon: Icons.notifications_outlined,
          ),
          LabeledValue(
            label: l.avgLeadTime,
            value: avgLead == null
                ? l.notSet
                : '${avgLead.toStringAsFixed(1)} ${l.minutesUnit}',
            icon: Icons.timer_outlined,
          ),
          LabeledValue(
            label: l.falseAlarmRate,
            value: decided.isEmpty
                ? l.notSet
                : _pct(falseAlarms / decided.length),
            icon: Icons.report_off_outlined,
          ),
          Gap.vSm,
          // The honest caveat. These are this patient's counts, not a validated
          // performance figure, and a doctor who reads them as the latter would
          // be over-trusting a handful of events.
          InfoNote(
            text: l.operatingPointNote,
            icon: Icons.info_outline,
            view: RiskView.unknown,
          ),
        ],
      ),
    );
  }
}

class _NotesSection extends StatelessWidget {
  const _NotesSection({
    required this.notes,
    required this.enabled,
    required this.onAdd,
  });

  final List<ClinicalNote> notes;
  final bool enabled;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return SectionCard(
      title: l.clinicalNotes,
      icon: Icons.note_alt_outlined,
      subtitle: l.clinicalNotesHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (notes.isEmpty)
            EmptyState(
              title: l.emptyTitle,
              body: l.clinicalNotesHint,
              icon: Icons.edit_note_outlined,
              compact: true,
            )
          else
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(n.text, style: theme.textTheme.bodyMedium),
                    Text(
                      [
                        TimeAgo.stamp(n.writtenAt),
                        if (!n.synced) l.pendingSync,
                      ].join(' · '),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          Gap.vXs,
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: enabled ? onAdd : null,
              icon: const Icon(Icons.add),
              label: Text(l.clinicalNotes),
            ),
          ),
        ],
      ),
    );
  }
}

class _OperatingPointSection extends StatelessWidget {
  const _OperatingPointSection({
    required this.current,
    required this.online,
    required this.enabled,
    required this.onApply,
  });

  final AlertSensitivity current;
  final bool online;
  final bool enabled;
  final ValueChanged<AlertSensitivity> onApply;

  static String _name(AlertSensitivity s, AppLocalizations l) => switch (s) {
    AlertSensitivity.low => l.opConservative,
    AlertSensitivity.medium => l.opBalanced,
    AlertSensitivity.high => l.opSensitive,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return SectionCard(
      title: l.perPatientSettings,
      icon: Icons.tune_outlined,
      subtitle: l.operatingPoints,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A table, not three vague words. §5.3 asks the doctor to trade
          // detection against false alarms, and they cannot do that without
          // seeing both numbers next to each other.
          Row(
            children: [
              Expanded(flex: 3, child: Text('', style: theme.textTheme.labelSmall)),
              Expanded(
                flex: 2,
                child: Text(
                  l.colSensitivity,
                  style: theme.textTheme.labelSmall,
                  textAlign: TextAlign.center,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  l.colFalseAlarmsPerHour,
                  style: theme.textTheme.labelSmall,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          const Divider(),
          for (final s in AlertSensitivity.values)
            _PointRow(
              point: s,
              label: _name(s, l),
              selected: s == current,
            ),
          Gap.vSm,
          // The same figure in the unit a consultation is held in. «كل ~٢ ساعة»
          // is a sentence a doctor can repeat to the patient; «0.45/hour» is not.
          InfoNote(
            text: l.opImpact(
              current.hoursBetweenFalseAlarms.isFinite
                  ? current.hoursBetweenFalseAlarms.toStringAsFixed(1)
                  : '—',
            ),
            icon: Icons.balance_outlined,
          ),
          Gap.vSm,
          InfoNote(text: l.operatingPointNote, icon: Icons.info_outline),
          if (!online) ...[
            Gap.vSm,
            // Not a generic offline banner: this specific control is the only
            // one on the screen that cannot be saved locally, so it says so
            // where the button is.
            InfoNote(
              text: l.errNoConnection,
              icon: Icons.cloud_off_outlined,
              view: RiskView.caution,
            ),
          ],
          Gap.vSm,
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final s in AlertSensitivity.values)
                OutlinedButton(
                  onPressed: (enabled && online && s != current)
                      ? () => onApply(s)
                      : null,
                  child: Text('${l.applyThreshold}: ${_name(s, l)}'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PointRow extends StatelessWidget {
  const _PointRow({
    required this.point,
    required this.label,
    required this.selected,
  });

  final AlertSensitivity point;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weight = selected ? FontWeight.w800 : FontWeight.w400;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? theme.colorScheme.primary : null,
                ),
                Gap.hXs,
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: weight,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _pct(point.detection),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: weight),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              point.falseAlarmsPerHour.toStringAsFixed(2),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: weight),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportsSection extends StatelessWidget {
  const _ReportsSection({
    required this.enabled,
    required this.onPdf,
    required this.onCsv,
  });

  final bool enabled;
  final VoidCallback onPdf;
  final VoidCallback onCsv;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return SectionCard(
      title: l.reportsSection,
      icon: Icons.description_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: A11y.minTouchTarget,
                  child: FilledButton.icon(
                    onPressed: enabled ? onPdf : null,
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: Text(l.exportPdf),
                  ),
                ),
              ),
              Gap.hSm,
              Expanded(
                child: SizedBox(
                  height: A11y.minTouchTarget,
                  child: OutlinedButton.icon(
                    onPressed: enabled ? onCsv : null,
                    icon: const Icon(Icons.table_view_outlined),
                    label: Text(l.exportCsv),
                  ),
                ),
              ),
            ],
          ),
          Gap.vSm,
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: enabled
                  ? () => Navigator.pushNamed(context, Routes.reports)
                  : null,
              icon: const Icon(Icons.table_chart_outlined),
              label: const Text('مركز التقارير الطبية الشاملة وتصدير Excel'),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteSheet extends StatefulWidget {
  const _NoteSheet();

  @override
  State<_NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends State<_NoteSheet> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.clinicalNotes, style: theme.textTheme.titleMedium),
          Gap.vXs,
          Text(
            l.clinicalNotesHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Gap.vMd,
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: l.noteLabel,
              alignLabelWithHint: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
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
                    // An empty note is not a note. Disabled rather than saved
                    // and hidden, so the doctor knows nothing was recorded.
                    onPressed: _text.text.trim().isEmpty
                        ? null
                        : () => Navigator.pop(context, _text.text),
                    child: Text(l.save),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
