import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../core/errors/failure.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/risk_indicator.dart';
import '../../core/ui/states.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../widgets/metrics_panel.dart';
import '../shared/alerts_list.dart';

/// §5.1 — the doctor's triage list: search, sort, filter, open.
///
/// The string table spells this screen out (`sortNeedsAttention`, `sortByName`,
/// `filterNewAlerts`, `filterBrokenDevices`, `filterLowAdherence`,
/// `searchByName`), and all of it is implemented below.
///
/// What moved out, and why:
///
/// * **The charts are gone from here.** They now live in the patient file
///   (§5.2), which is where they mean something. On this screen they were fed by
///   `monitoring.latestReading` — one signal window, for whichever patient the
///   app happened to be following — and drawn under a heading that implied it
///   belonged to the list above.
/// * **So are the export buttons.** They exported `patients.first` no matter who
///   the doctor was looking at, which is the kind of bug that puts one patient's
///   record in another's report. Export is per-patient in the file screen.
/// * **The status badge is per patient.** Same defect as the family screen had:
///   a single app-wide assessment was drawn beside every name.
///
/// «أجهزة معطلة» is derived, not reported: the app only polls the headband of the
/// patient it is actively following, so a per-patient connection flag does not
/// exist. A patient whose newest assessment is older than [_staleAfter] is listed
/// as not reporting — which is what the filter is actually for.
class DoctorHomeScreen extends StatefulWidget {
  const DoctorHomeScreen({super.key});

  @override
  State<DoctorHomeScreen> createState() => _DoctorHomeScreenState();
}

/// How long a patient may go without a new assessment before the list treats
/// their device as not reporting.
const Duration _staleAfter = Duration(minutes: 30);

/// Below this, §3.4's adherence figure is a clinical finding rather than a
/// statistic — the same boundary the patient file uses.
const double _lowAdherence = 0.8;

enum _Sort { attention, name }

enum _Filter { newAlerts, brokenDevice, lowAdherence }

class _DoctorHomeScreenState extends State<DoctorHomeScreen> {
  final _search = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  Failure? _failure;
  List<_Row> _rows = const [];
  _Sort _sort = _Sort.attention;
  final Set<_Filter> _filters = {};

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final rows = <_Row>[];
      for (final p in app.auth.accessiblePatients()) {
        final assessments = await app.db.assessmentsFor(p.patientId, limit: 1);
        final alerts = await app.db.alertsFor(p.patientId, limit: 100);
        final decided = await app.db.adjudicatedAlertIds(p.patientId);
        // Same rule as the adjudication queue (§5.4): informational alerts are
        // never pending, and an unrecognised severity is.
        final pending = alerts
            .where((a) =>
                !decided.contains(a.id) &&
                alertSeverity(a.severity, l).view != RiskView.safe)
            .length;
        rows.add(_Row(
          profile: p,
          latest: assessments.isEmpty ? null : assessments.first,
          alerts: alerts,
          pendingAdjudications: pending,
          adherence: await app.medication.adherence(p.patientId),
        ));
      }
      if (!mounted) return;
      setState(() {
        _rows = rows;
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

  Future<void> _refresh() async {
    final app = context.read<AppState>();
    await app.refreshFromCloud();
    await _load();
  }

  /// Select, then open. The file screen loads that patient's notes and consents,
  /// and both are per-patient state on `CareService`.
  Future<void> _open(_Row row) async {
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await app.selectPatient(row.profile.patientId);
    } catch (_) {
      // Not fatal: the file screen re-points the care service itself.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await Navigator.pushNamed(
      context,
      Routes.doctorPatient,
      arguments: PatientRouteArgs(patientId: row.profile.patientId),
    );
    if (!mounted) return;
    await _load();
  }

  /// Search, then filter, then sort — in that order, so the sort applies to what
  /// the doctor can actually see.
  List<_Row> _visible() {
    final q = _search.text.trim().toLowerCase();
    final out = _rows.where((r) {
      if (q.isNotEmpty &&
          !r.profile.name.toLowerCase().contains(q) &&
          !r.profile.patientId.toLowerCase().contains(q)) {
        return false;
      }
      for (final f in _filters) {
        final match = switch (f) {
          _Filter.newAlerts => r.unacked > 0,
          _Filter.brokenDevice => r.notReporting,
          _Filter.lowAdherence => r.adherence < _lowAdherence,
        };
        // Filters are additive: every selected one must hold, otherwise
        // selecting two of them would widen the list instead of narrowing it.
        if (!match) return false;
      }
      return true;
    }).toList();
    out.sort((a, b) => switch (_sort) {
      _Sort.name => a.profile.name.compareTo(b.profile.name),
      _Sort.attention => b.attentionScore.compareTo(a.attentionScore),
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final rows = _visible();
    final pending = _rows.fold<int>(0, (n, r) => n + r.pendingAdjudications);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.doctorHome),
        actions: [
          IconButton(
            tooltip: l.adjudicationTitle,
            onPressed: () =>
                Navigator.pushNamed(context, Routes.doctorAdjudication),
            icon: Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: const Icon(Icons.gavel_outlined),
            ),
          ),
          IconButton(
            tooltip: l.refresh,
            onPressed: _loading || _busy ? null : _refresh,
            icon: const Icon(Icons.cloud_download_outlined),
          ),
          IconButton(
            tooltip: l.settingsTitle,
            onPressed: () =>
                Navigator.pushNamed(context, Routes.patientSettings),
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: l.logout,
            onPressed: app.signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: AsyncView<List<_Row>>(
        loading: _loading,
        failure: _failure,
        value: _rows,
        isEmpty: (v) => v.isEmpty,
        onRetry: _load,
        emptyTitle: l.noPatientsYet,
        emptyBody: l.emptyBody,
        emptyIcon: Icons.people_outline,
        builder: (context, _) => RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: Insets.pageBottomSafe,
            children: [
              OfflineBanner(
                visible: !app.apiOnline,
                lastUpdateLabel: TimeAgo.since(app.care.lastSyncedAt, l),
                pendingCount: app.care.pendingCount,
              ),
              TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.searchByName,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l.cancel,
                          onPressed: () => setState(_search.clear),
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
              Gap.vSm,
              _Controls(
                sort: _sort,
                filters: _filters,
                onSort: (s) => setState(() => _sort = s),
                onToggle: (f) => setState(() {
                  if (!_filters.remove(f)) _filters.add(f);
                }),
              ),
              Gap.vMd,
              SectionCard(
                title: l.patientsList,
                icon: Icons.people_outline,
                trailing: Text(
                  '${rows.length}/${_rows.length}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                child: rows.isEmpty
                    // Distinct from the page-level empty state above: there *are*
                    // patients, they are just all filtered out. Saying «لا مرضى»
                    // here would look like the list failed to load.
                    ? EmptyState(
                        title: l.emptyTitle,
                        body: l.emptyBody,
                        icon: Icons.filter_alt_off_outlined,
                        compact: true,
                      )
                    : Column(
                        children: [
                          for (final r in rows)
                            _PatientTile(
                              row: r,
                              enabled: !_busy,
                              onOpen: () => _open(r),
                            ),
                        ],
                      ),
              ),
              Gap.vMd,
              SectionCard(
                title: l.modelPerformance,
                icon: Icons.insights_outlined,
                subtitle: l.operatingPointNote,
                child: const MetricsPanel(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sort and filter controls. Chips rather than a segmented button: the labels are
/// long in Arabic and wrapping is better than truncating a filter nobody can
/// then read.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.sort,
    required this.filters,
    required this.onSort,
    required this.onToggle,
  });

  final _Sort sort;
  final Set<_Filter> filters;
  final ValueChanged<_Sort> onSort;
  final ValueChanged<_Filter> onToggle;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      children: [
        ChoiceChip(
          avatar: const Icon(Icons.priority_high, size: 18),
          label: Text(l.sortNeedsAttention),
          selected: sort == _Sort.attention,
          onSelected: (_) => onSort(_Sort.attention),
        ),
        ChoiceChip(
          avatar: const Icon(Icons.sort_by_alpha, size: 18),
          label: Text(l.sortByName),
          selected: sort == _Sort.name,
          onSelected: (_) => onSort(_Sort.name),
        ),
        FilterChip(
          label: Text(l.filterNewAlerts),
          selected: filters.contains(_Filter.newAlerts),
          onSelected: (_) => onToggle(_Filter.newAlerts),
        ),
        FilterChip(
          label: Text(l.filterBrokenDevices),
          selected: filters.contains(_Filter.brokenDevice),
          onSelected: (_) => onToggle(_Filter.brokenDevice),
        ),
        FilterChip(
          label: Text(l.filterLowAdherence),
          selected: filters.contains(_Filter.lowAdherence),
          onSelected: (_) => onToggle(_Filter.lowAdherence),
        ),
      ],
    );
  }
}

class _PatientTile extends StatelessWidget {
  const _PatientTile({
    required this.row,
    required this.enabled,
    required this.onOpen,
  });

  final _Row row;
  final bool enabled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final label = row.label;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: InkWell(
        onTap: enabled ? onOpen : null,
        borderRadius: Radii.rMd,
        child: Padding(
          padding: Insets.tile,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      row.profile.name.isEmpty
                          ? row.profile.patientId
                          : row.profile.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  RiskBadge(view: row.view, dense: true),
                ],
              ),
              if (row.profile.diagnosis.isNotEmpty)
                Text(
                  row.profile.diagnosis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              Gap.vXs,
              Text(
                label == null
                    ? l.offlineNoData
                    : '${l.lastKnownStatus}: '
                          '${RiskCopy.title(label.bandView, l)} · '
                          '${TimeAgo.since(row.observedAt, l)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Gap.vXs,
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  _Chip(
                    icon: Icons.notifications_none_outlined,
                    label: l.alerts7d,
                    value: '${row.alerts7d}',
                    alert: row.unacked > 0,
                  ),
                  _Chip(
                    icon: Icons.medication_outlined,
                    label: l.adherenceShort,
                    value: '${(row.adherence * 100).round()}%',
                    alert: row.adherence < _lowAdherence,
                  ),
                  if (row.pendingAdjudications > 0)
                    _Chip(
                      icon: Icons.gavel_outlined,
                      label: l.adjPending,
                      value: '${row.pendingAdjudications}',
                      alert: true,
                    ),
                  if (row.notReporting)
                    _Chip(
                      icon: Icons.sensors_off_outlined,
                      label: l.filterBrokenDevices,
                      value: '',
                      alert: true,
                    ),
                ],
              ),
              Gap.vXs,
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: SizedBox(
                  height: A11y.minTouchTarget,
                  child: TextButton.icon(
                    onPressed: enabled ? onOpen : null,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: Text(l.openFile),
                  ),
                ),
              ),
              const Divider(height: Gap.sm),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.value,
    this.alert = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = alert
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        Gap.hXs,
        Text(
          value.isEmpty ? label : '$label: $value',
          style: theme.textTheme.bodySmall?.copyWith(
            color: color,
            fontWeight: alert ? FontWeight.w700 : null,
          ),
        ),
      ],
    );
  }
}

/// One patient in the triage list, plus the numbers the list ranks and filters on.
class _Row {
  const _Row({
    required this.profile,
    required this.latest,
    required this.alerts,
    required this.pendingAdjudications,
    required this.adherence,
  });

  final PatientProfile profile;
  final RiskAssessment? latest;
  final List<AlertItem> alerts;
  final int pendingAdjudications;
  final double adherence;

  RiskLabel? get label => latest?.label ?? profile.currentStatus;

  DateTime? get observedAt => latest?.timestamp ?? profile.lastUpdated;

  int get unacked => alerts.where((a) => !a.acknowledged).length;

  int get alerts7d {
    final since = DateTime.now().subtract(const Duration(days: 7));
    return alerts.where((a) => a.timestamp.isAfter(since)).length;
  }

  /// No fresh assessment ⇒ nothing is arriving from that patient's device.
  bool get notReporting {
    final at = observedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > _staleAfter;
  }

  RiskView get view => RiskViewX.resolve(
    label: label,
    observedAt: observedAt,
    // An assessment row is the only thing that counts as having observed this
    // patient. `profile.currentStatus` defaults to `stable` and
    // `profile.lastUpdated` to «now» on a profile this device has never synced,
    // so trusting them would paint a brand-new patient green.
    dataAvailable: latest != null,
  );

  /// Ranking for «الأكثر حاجة للانتباه».
  ///
  /// Weighted, not alphabetical by severity: a confirmed high-risk state
  /// outranks an unacknowledged warning, which outranks a queue of events to
  /// review, which outranks poor adherence. Silence from a device sits above
  /// adherence too — a patient we cannot see is a worse position to be in than a
  /// patient we can see is missing doses.
  int get attentionScore {
    var score = 0;
    score += switch (view) {
      RiskView.danger => 1000,
      RiskView.caution => 400,
      RiskView.unknown => 120,
      RiskView.safe => 0,
    };
    score += unacked * 50;
    score += pendingAdjudications * 10;
    if (notReporting) score += 60;
    if (adherence < _lowAdherence) score += 30;
    return score;
  }
}
