import '../../core/enums.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failure.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../core/utils/external_actions.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/care_models.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../services/report_service.dart';
import '../shared/alerts_list.dart';

/// Everything the history screen needs, fetched once per reload.
class _HistoryData {
  _HistoryData({
    required this.profile,
    required this.assessments,
    required this.alerts,
    required this.seizures,
    required this.events,
  });

  final PatientProfile? profile;
  final List<RiskAssessment> assessments;
  final List<AlertItem> alerts;
  final List<SeizureLog> seizures;
  final List<PredictionEvent> events;

  bool get isEmpty =>
      alerts.isEmpty &&
      seizures.isEmpty &&
      events.isEmpty &&
      assessments.isEmpty;
}

/// One row of the merged timeline.
class _Event {
  _Event({
    required this.at,
    required this.view,
    required this.title,
    this.subtitle,
    required this.icon,
  });

  final DateTime at;
  final RiskView view;
  final String title;
  final String? subtitle;
  final IconData icon;
}

/// §3.3 — history and analytics: statistics, a colour-coded monthly calendar, a
/// merged event timeline, and export.
///
/// Everything on this screen is read from SQLite, so it works with no network.
/// The one thing it deliberately does **not** do is imply causation: the trigger
/// diary lives on its own screen and states co-occurrence only (§3.3, §11.4).
class PatientHistoryScreen extends StatefulWidget {
  const PatientHistoryScreen({super.key});

  @override
  State<PatientHistoryScreen> createState() => _PatientHistoryScreenState();
}

class _PatientHistoryScreenState extends State<PatientHistoryScreen> {
  final _reports = ReportService();
  late Future<_HistoryData> _future;
  late DateTime _month;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _future = _load();
  }

  AppState get _app => context.read<AppState>();

  Future<_HistoryData> _load() async {
    final app = _app;
    final pid = app.auth.currentUser?.uid;
    if (pid == null || !app.auth.canAccessPatient(pid)) {
      throw const Failure(FailureKind.notFound);
    }
    final db = app.db;
    return _HistoryData(
      profile: app.auth.patientById(pid),
      assessments: await db.assessmentsFor(pid, limit: 500),
      alerts: await db.alertsFor(pid, limit: 200),
      seizures: await db.seizureLogsFor(pid, limit: 200),
      events: await db.predictionEventsFor(pid, limit: 200),
    );
  }

  void _reload() => setState(() => _future = _load());

  void _shiftMonth(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
  }

  // --- export ---------------------------------------------------------------

  Future<void> _exportPdf(_HistoryData d) async {
    final l = AppLocalizations.of(context);
    final profile = d.profile;
    if (profile == null) return;
    setState(() => _exporting = true);
    try {
      final doc = await _reports.toPdf(
        patient: profile,
        assessments: d.assessments
            .where((row) => _inMonth(row.timestamp))
            .toList(),
        alerts: d.alerts.where((row) => _inMonth(row.timestamp)).toList(),
      );
      await Printing.layoutPdf(onLayout: (_) => doc.save());
      if (mounted) AppSnack.success(context, l.reportReady);
    } catch (_) {
      if (mounted) AppSnack.error(context, l.exportFailed);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportCsv(_HistoryData d) async {
    final l = AppLocalizations.of(context);
    final profile = d.profile;
    if (profile == null) return;
    setState(() => _exporting = true);
    try {
      final csv = _reports.toCsv(
        patient: profile,
        assessments: d.assessments
            .where((row) => _inMonth(row.timestamp))
            .toList(),
        alerts: d.alerts.where((row) => _inMonth(row.timestamp)).toList(),
      );
      // No file picker is wired, and a share sheet cannot be relied on offline.
      // The clipboard always works, so the export never silently does nothing.
      final ok = await ExternalActions.copy(csv);
      if (!mounted) return;
      ok
          ? AppSnack.success(context, l.copied)
          : AppSnack.error(context, l.exportFailed);
    } catch (_) {
      if (mounted) AppSnack.error(context, l.exportFailed);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // --- derived numbers ------------------------------------------------------

  bool _inMonth(DateTime t) =>
      t.toLocal().year == _month.year && t.toLocal().month == _month.month;

  int _seizuresThisMonth(_HistoryData d) =>
      d.seizures.where((s) => _inMonth(s.occurredAt)).length;

  // --- day classification ---------------------------------------------------

  bool _sameDay(DateTime a, DateTime b) =>
      a.toLocal().year == b.toLocal().year &&
      a.toLocal().month == b.toLocal().month &&
      a.toLocal().day == b.toLocal().day;

  /// Worst thing that happened on [day] — and «unknown» when the day holds no
  /// data at all. A day the device was off must not be painted green (§11.1).
  RiskView _dayView(DateTime day, _HistoryData d, AppLocalizations l) {
    if (d.seizures.any((s) => _sameDay(s.occurredAt, day))) {
      return RiskView.danger;
    }
    final dayAlerts = d.alerts.where((a) => _sameDay(a.timestamp, day));
    if (dayAlerts.any((a) => alertSeverity(a.severity, l).view.isCritical)) {
      return RiskView.danger;
    }
    if (dayAlerts.isNotEmpty) return RiskView.caution;
    final valid = d.assessments.where(
      (a) =>
          _sameDay(a.timestamp, day) &&
          a.confidence > 0 &&
          a.features['assessment_valid'] != false,
    );
    if (valid.any((a) => a.label == RiskLabel.highRisk)) return RiskView.danger;
    if (valid.any((a) => a.label == RiskLabel.watch)) return RiskView.caution;
    if (valid.isNotEmpty) return RiskView.safe;
    return RiskView.unknown;
  }

  List<_Event> _timeline(_HistoryData d, AppLocalizations l) {
    final out = <_Event>[
      for (final s in d.seizures.where((s) => _inMonth(s.occurredAt)))
        _Event(
          at: s.occurredAt,
          view: RiskView.danger,
          icon: Icons.bolt_outlined,
          title: _seizureTypeLabel(s.type, l),
          subtitle: s.durationSeconds == null
              ? null
              : '${l.seizureDuration}: ${s.durationSeconds} ${l.secondsUnit}',
        ),
      for (final a in d.alerts.where((a) => _inMonth(a.timestamp)))
        _Event(
          at: a.timestamp,
          view: alertSeverity(a.severity, l).view,
          icon: Icons.notifications_active_outlined,
          title: alertSeverity(a.severity, l).label,
          subtitle: a.message,
        ),
      for (final e in d.events.where((e) => _inMonth(e.firedAt)))
        _Event(
          at: e.firedAt,
          view: e.outcome == 'cancelled_false_alarm'
              ? RiskView.caution
              : RiskView.danger,
          icon: Icons.online_prediction_outlined,
          title: e.outcome == 'cancelled_false_alarm'
              ? l.falseAlarm
              : l.severityPreAlert,
          subtitle:
              '${l.preictalProb} ${(e.preictalProb * 100).round()}%'
              '${e.leadTimeMin == null ? '' : ' · ${l.leadTime} ${l.minutesApprox(e.leadTimeMin!.round())}'}',
        ),
    ];
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  static String _seizureTypeLabel(SeizureType t, AppLocalizations l) =>
      switch (t) {
        SeizureType.focal => l.seizureTypeFocal,
        SeizureType.generalized => l.seizureTypeGeneralized,
        SeizureType.absence => l.seizureTypeAbsence,
        SeizureType.other => l.seizureTypeOther,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF6F9FD),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(
          l.historyTitle,
          style: const TextStyle(
            color: Color(0xFF0D253C),
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        actions: [
          IconButton(
            tooltip: l.refresh,
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF6B7A99)),
          ),
        ],
      ),
      body: ResponsiveContent(
        maxWidth: 1000,
        child: FutureBuilder<_HistoryData>(
          future: _future,
          builder: (context, snap) => AsyncView<_HistoryData>(
            loading: snap.connectionState == ConnectionState.waiting,
            failure: snap.hasError ? Failure.from(snap.error!) : null,
            value: snap.data,
            isEmpty: (d) => d.isEmpty,
            emptyTitle: l.noHistoryYet,
            emptyBody: l.emptyBody,
            emptyIcon: Icons.history_outlined,
            onRetry: _reload,
            builder: _content,
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, _HistoryData d) {
    final l = AppLocalizations.of(context);
    final events = d.events.where((e) => _inMonth(e.firedAt)).toList();
    final cancelled = events
        .where((e) => e.outcome == 'cancelled_false_alarm')
        .length;
    final timeline = _timeline(d, l);

    return ListView(
      padding: Insets.pageBottomSafe,
      children: [
        InfoNote(
          text: l.isArabic
              ? 'السجل محلي وقد يكون غير مكتمل. لون اليوم يلخص السجلات المحفوظة ولا يثبت استمرار المراقبة طوال اليوم. البلاغات ليست تشخيصًا مؤكدًا.'
              : 'Local records may be incomplete. Day colors summarize saved records, not full-day monitoring. Reports are not confirmed diagnoses.',
        ),
        Gap.vMd,
        SectionCard(
          title: l.statsTitle,
          icon: Icons.insights_outlined,
          child: Column(
            children: [
              LabeledValue(
                label: l.seizuresThisMonth,
                value: '${_seizuresThisMonth(d)}',
                icon: Icons.bolt_outlined,
              ),
              Gap.vSm,
              LabeledValue(
                label: l.totalAlerts,
                value: '${d.alerts.where((a) => _inMonth(a.timestamp)).length}',
                icon: Icons.notifications_none_outlined,
              ),
              Gap.vSm,
              LabeledValue(
                label: l.isArabic
                    ? 'أحداث النموذج في الشهر'
                    : 'Model events this month',
                value: '${events.length}',
                icon: Icons.timer_outlined,
              ),
              Gap.vSm,
              LabeledValue(
                label: l.isArabic
                    ? 'تنبيهات ألغاها المستخدم'
                    : 'Alerts cancelled by the user',
                value: '$cancelled',
                icon: Icons.report_off_outlined,
              ),
            ],
          ),
        ),
        Gap.vMd,
        _Calendar(
          month: _month,
          onShift: _shiftMonth,
          viewFor: (day) => _dayView(day, d, l),
        ),
        Gap.vMd,
        SectionCard(
          title: l.eventsTimeline,
          subtitle: l.monthYear(_month.year, _month.month),
          icon: Icons.timeline_outlined,
          child: timeline.isEmpty
              ? EmptyState(
                  title: l.noEventsThisMonth,
                  icon: Icons.event_busy_outlined,
                  compact: true,
                )
              : Column(
                  children: [for (final e in timeline) _TimelineRow(event: e)],
                ),
        ),
        Gap.vMd,
        SectionCard(
          title: l.triggersTitle,
          icon: Icons.psychology_alt_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InfoNote(text: l.correlationDisclaimer),
              Gap.vSm,
              SizedBox(
                height: A11y.minTouchTarget,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.of(context).pushNamed(Routes.patientTriggers),
                  icon: const Icon(Icons.edit_note_outlined),
                  label: Text(l.triggerHistory),
                ),
              ),
            ],
          ),
        ),
        if (d.profile != null) ...[
          Gap.vMd,
          SectionCard(
            title: l.reportsSection,
            icon: Icons.description_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: A11y.minTouchTarget,
                  child: FilledButton.icon(
                    onPressed: _exporting ? null : () => _exportPdf(d),
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: Text(l.exportPdf),
                  ),
                ),
                Gap.vSm,
                SizedBox(
                  height: A11y.minTouchTarget,
                  child: OutlinedButton.icon(
                    onPressed: _exporting ? null : () => _exportCsv(d),
                    icon: const Icon(Icons.table_chart_outlined),
                    label: Text(l.exportCsv),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Colour-coded month grid. Every cell carries colour **and** an icon **and** a
/// screen-reader sentence, so the state survives colour-blindness, greyscale and
/// TalkBack alike (§2.4, §7).
class _Calendar extends StatelessWidget {
  const _Calendar({
    required this.month,
    required this.onShift,
    required this.viewFor,
  });

  final DateTime month;
  final void Function(int delta) onShift;
  final RiskView Function(DateTime day) viewFor;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final first = DateTime(month.year, month.month);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Sunday-first grid: DateTime.weekday is 1=Mon … 7=Sun, so `% 7` maps Sunday
    // to column 0 and Saturday to column 6.
    final leading = first.weekday % 7;
    final today = DateTime.now();
    final isCurrentMonth =
        month.year == today.year && month.month == today.month;

    return SectionCard(
      title: l.monthlyCalendar,
      icon: Icons.calendar_month_outlined,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l.prevMonth,
            onPressed: () => onShift(-1),
            icon: const Icon(Icons.chevron_right),
          ),
          IconButton(
            tooltip: l.nextMonth,
            // Never page past the current month: those cells hold no data by
            // definition, and an empty future month reads like missing history.
            onPressed: isCurrentMonth ? null : () => onShift(1),
            icon: const Icon(Icons.chevron_left),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.monthYear(month.year, month.month),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          Gap.vSm,
          Row(
            children: [
              for (final label in l.weekdayLabels)
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          Gap.vXs,
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: Gap.xxs,
            crossAxisSpacing: Gap.xxs,
            children: [
              for (var i = 0; i < leading; i++) const SizedBox.shrink(),
              for (var day = 1; day <= daysInMonth; day++)
                _DayCell(
                  day: day,
                  view: viewFor(DateTime(month.year, month.month, day)),
                ),
            ],
          ),
          Gap.vMd,
          const _Legend(),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, required this.view});

  final int day;
  final RiskView view;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = AppColors.of(context, view);
    final state = switch (view) {
      RiskView.safe => l.calendarLegendSafe,
      RiskView.caution => l.calendarLegendCaution,
      RiskView.danger => l.calendarLegendDanger,
      RiskView.unknown => l.unknown,
    };
    return Semantics(
      label: '$day — $state',
      child: ExcludeSemantics(
        child: Container(
          decoration: BoxDecoration(
            color: colors.container,
            borderRadius: Radii.rSm,
            border: Border.all(color: colors.border),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$day',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Icon(AppColors.iconFor(view), size: 10, color: colors.foreground),
            ],
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final items = <(RiskView, String)>[
      (RiskView.safe, l.calendarLegendSafe),
      (RiskView.caution, l.calendarLegendCaution),
      (RiskView.danger, l.calendarLegendDanger),
      (RiskView.unknown, l.unknown),
    ];
    return Wrap(
      spacing: Gap.md,
      runSpacing: Gap.xs,
      children: [
        for (final (view, label) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppColors.iconFor(view),
                size: 14,
                color: AppColors.of(context, view).foreground,
              ),
              Gap.hXs,
              Text(label, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
      ],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.event});

  final _Event event;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context, event.view);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE4EDF7), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0D253C).withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: colors.container,
                shape: BoxShape.circle,
              ),
              child: Icon(event.icon, size: 20, color: colors.foreground),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: Color(0xFF0D253C),
                    ),
                  ),
                  if (event.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      event.subtitle!,
                      style: const TextStyle(
                        color: Color(0xFF6B7A99),
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(
                    TimeAgo.stamp(event.at),
                    style: const TextStyle(
                      color: Color(0xFF9E9E9E),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
