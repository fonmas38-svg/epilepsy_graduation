import 'dart:async';
import '../shared/clinical_messages_screen.dart';
import '../shared/account_screen.dart';
import '../../core/ui/workspace_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../widgets/patient_location_card.dart';

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
import '../../models/care_models.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../patient/consents_screen.dart' show consentLevelLabel;
import '../shared/alerts_list.dart';

/// §4.1 — the family member's list of the people they are following.
///
/// Three things this screen gets right that the first version did not:
///
/// * **Each patient's status is that patient's.** The old build read
///   `monitoring.latestAssessment` — a single value for the whole app — and drew
///   it next to every name in the list. With two linked patients, one of them was
///   always shown someone else's condition. Every row is now read per-patient
///   from SQLite.
/// * **Stale is stated, not coloured over.** A family member's copy is only as
///   fresh as the last sync, so the badge goes through [RiskViewX.resolve] and
///   turns «غير معروف» once the reading ages out. The last known label is still
///   printed underneath as «آخر حالة معروفة …» so nothing is hidden — it is just
///   no longer presented as *now*.
/// * **Consent is visible.** §4.3 lets the patient decide how much a relative
///   sees. A limit nobody can see looks like a bug, so the granted tier and what
///   it covers are printed on the patient's card.
class CaregiverHomeScreen extends StatefulWidget {
  const CaregiverHomeScreen({super.key});

  @override
  State<CaregiverHomeScreen> createState() => _CaregiverHomeScreenState();
}

class _CaregiverHomeScreenState extends State<CaregiverHomeScreen> {
  bool _loading = true;
  int _tab = 0;
  bool _busy = false;
  Failure? _failure;
  List<_Row> _rows = const [];

  /// Keeps the list current while it is on screen: cloud pull on open, then
  /// every minute (new patients, links, alerts and statuses).
  Timer? _autoRefresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _load();
      if (mounted) unawaited(_refresh());
    });
    _autoRefresh = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _failure = null;
    });
    final owner = app.auth.currentUser;
    final origin = app.api.baseUrl;
    final revision = app.api.tokens.revision;
    bool current() =>
        mounted &&
        AppUser.sameSessionOwner(owner, app.auth.currentUser) &&
        origin == app.api.baseUrl &&
        revision == app.api.tokens.revision;
    try {
      final patients = app.auth.accessiblePatients();
      final snapshot = await app.db.dashboardSnapshot(
        patients.map((p) => p.patientId).toList(),
        serverOrigin: app.dataOrigin,
        includeCare: false,
      );
      if (!current()) return;
      final rows = <_Row>[];
      for (final p in patients) {
        final assessment = snapshot.latest[p.patientId];
        final alerts = snapshot.alerts[p.patientId] ?? <AlertItem>[];
        rows.add(_Row(profile: p, latest: assessment, alerts: alerts));
      }
      // The one that needs attention first: unacknowledged alerts, then recency.
      rows.sort((a, b) {
        final byUnacked = b.unacked.compareTo(a.unacked);
        if (byUnacked != 0) return byUnacked;
        final at = a.observedAt, bt = b.observedAt;
        if (at == null && bt == null) {
          return a.profile.name.compareTo(b.profile.name);
        }
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
      if (!current()) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!current()) return;
      setState(() {
        _failure = Failure.from(e);
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    final app = context.read<AppState>();
    // Cloud first, then re-read: a pull that changed nothing still leaves the
    // list showing what is on this device, which is the honest fallback.
    await app.refreshFromCloud();
    await _load();
  }

  /// Point the app at this patient, then open their card.
  ///
  /// The selection has to finish before the push: the detail screen reads the
  /// consent grants from `CareService`, and those are loaded per patient.
  Future<void> _open(_Row row) async {
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await app.selectPatient(row.profile.patientId);
    } catch (_) {
      // Selection failing is not fatal — the card degrades to what is cached.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _PatientCardScreen(row: row)),
    );
    if (!mounted) return;
    // An acknowledgement made inside changes the counts out here.
    await _load();
  }

  void _respond(AlertItem alert) => Navigator.pushNamed(
    context,
    Routes.familyRespond,
    arguments: PatientRouteArgs(patientId: alert.patientId, alertId: alert.id),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();

    return PopScope(
      canPop: true,
      child: WorkspaceScaffold(
        appBar: _tab == 0
            ? AppBar(
                title: Text(l.isArabic ? 'مرضاي' : 'My patients'),
                actions: [
                  IconButton(
                    tooltip: l.refresh,
                    onPressed: _loading || _busy ? null : _refresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              )
            : null,
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        body: IndexedStack(
          index: _tab,
          children: [
            AsyncView<List<_Row>>(
              loading: _loading,
              failure: _failure,
              value: _rows,
              isEmpty: (v) => v.isEmpty,
              onRetry: _load,
              emptyTitle: l.noLinkedPatients,
              emptyBody: l.noLinkedPatientsBody,
              emptyIcon: Icons.people_outline,
              builder: (context, rows) => RefreshIndicator(
                onRefresh: _refresh,
                child: ResponsiveContent(
                  maxWidth: 850,
                  child: ListView(
                    padding: Insets.pageBottomSafe,
                    children: [
                      OfflineBanner(
                        visible: !app.apiOnline,
                        mode: app.operatingMode,
                        onSyncNow: app.syncNow,
                        lastUpdateLabel: app.care.lastSyncedAt == null
                            ? null
                            : TimeAgo.since(app.care.lastSyncedAt, l),
                        pendingCount: app.care.pendingCount,
                      ),
                      // Patients and alerts first; the last shared location
                      // follows (often empty, so it should not lead).
                      SectionCard(
                        title: l.linkedPatients,
                        icon: Icons.people_outline,
                        trailing: Text(
                          '${rows.length}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < rows.length; i++)
                              _PatientRowTile(
                                row: rows[i],
                                enabled: !_busy,
                                onOpen: () => _open(rows[i]),
                                onRespond: rows[i].newestUnacked == null
                                    ? null
                                    : () => _respond(rows[i].newestUnacked!),
                                last: i == rows.length - 1,
                              ),
                          ],
                        ),
                      ),
                      Gap.vMd,
                      _RecentSection(rows: rows, onRespond: _respond),
                      Gap.vMd,
                      const _CaregiverLocationTrackerCard(),
                    ],
                  ),
                ),
              ),
            ),
            const ClinicalMessagesScreen(),
            const AccountScreen(embedded: true),
          ],
        ),
      ),
    );
  }
}

/// One followed patient plus the little that is needed to rank and describe them.
class _Row {
  const _Row({
    required this.profile,
    required this.latest,
    required this.alerts,
  });

  final PatientProfile profile;
  final RiskAssessment? latest;
  final List<AlertItem> alerts;

  /// The newest assessment wins over `profile.currentStatus`: the profile is
  /// refreshed by a sync, the assessment by the device.
  bool get hasAssessment =>
      latest != null &&
      latest!.confidence > 0 &&
      latest!.features['assessment_valid'] != false;

  RiskLabel? get label => hasAssessment ? latest!.label : null;

  DateTime? get observedAt => hasAssessment ? latest!.timestamp : null;

  int get unacked => alerts.where((a) => !a.acknowledged).length;

  AlertItem? get newestUnacked {
    for (final a in alerts) {
      if (!a.acknowledged) return a;
    }
    return null;
  }

  /// What the badge may claim. Never `safe` on evidence older than five minutes —
  /// see the class comment on [CaregiverHomeScreen].
  RiskView get view => RiskViewX.resolve(
    label: label,
    observedAt: observedAt,
    // An assessment row is the only thing that counts as having observed this
    // patient. `profile.currentStatus` defaults to `stable` and
    // `profile.lastUpdated` to «now» on a profile this device has never synced,
    // so trusting them would paint a brand-new patient green.
    dataAvailable:
        latest != null &&
        latest!.confidence > 0 &&
        latest!.features['assessment_valid'] != false,
  );
}

class _PatientRowTile extends StatelessWidget {
  const _PatientRowTile({
    required this.row,
    required this.enabled,
    required this.onOpen,
    required this.onRespond,
    this.last = false,
  });

  final _Row row;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback? onRespond;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final label = row.label;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
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
          Gap.vXs,
          // The label and its age, stated as history. This is the line that keeps
          // the grey «غير معروف» badge above from throwing information away.
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
          if (row.unacked > 0) ...[
            Gap.vXs,
            Row(
              children: [
                Icon(
                  Icons.notifications_active_outlined,
                  size: 16,
                  color: theme.colorScheme.error,
                ),
                Gap.hXs,
                Text(
                  '${l.attentionNeeded} · ${row.unacked}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
          Gap.vXs,
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: A11y.minTouchTarget,
                  child: OutlinedButton.icon(
                    onPressed: enabled ? onOpen : null,
                    icon: const Icon(Icons.person_outline),
                    label: Text(l.openPatient),
                  ),
                ),
              ),
              Gap.hXs,
              IconButton(
                tooltip: 'التقارير وتصدير Excel',
                onPressed: enabled
                    ? () => Navigator.pushNamed(
                        context,
                        Routes.reports,
                        arguments: PatientRouteArgs(
                          patientId: row.profile.patientId,
                          patientName: row.profile.name,
                        ),
                      )
                    : null,
                icon: const Icon(Icons.table_chart_outlined),
              ),
              IconButton(
                tooltip: 'الرسائل والتوجيهات',
                onPressed: enabled
                    ? () => Navigator.pushNamed(
                        context,
                        Routes.messages,
                        arguments: PatientRouteArgs(
                          patientId: row.profile.patientId,
                          patientName: row.profile.name,
                        ),
                      )
                    : null,
                icon: const Icon(Icons.chat_bubble_outline),
              ),
              if (onRespond != null) ...[
                Gap.hSm,
                Expanded(
                  child: SizedBox(
                    height: A11y.minTouchTarget,
                    child: FilledButton.icon(
                      onPressed: enabled ? onRespond : null,
                      icon: const Icon(Icons.directions_run),
                      label: Text(l.respond),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (!last) const Divider(height: Gap.lg),
        ],
      ),
    );
  }
}

/// Alerts across everyone this person follows, newest first.
///
/// Merged rather than kept per patient: a relative following two people wants to
/// know what happened, in order. Whose it was is printed on the row.
class _RecentSection extends StatelessWidget {
  const _RecentSection({required this.rows, required this.onRespond});

  final List<_Row> rows;
  final void Function(AlertItem) onRespond;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final merged = <(AlertItem, String)>[];
    for (final r in rows) {
      for (final a in r.alerts) {
        merged.add((a, r.profile.name));
      }
    }
    merged.sort((x, y) => y.$1.timestamp.compareTo(x.$1.timestamp));
    final shown = merged.take(15).toList();

    return SectionCard(
      title: l.alertsTitle,
      icon: Icons.notifications_none_outlined,
      child: shown.isEmpty
          ? EmptyState(
              title: l.noAlerts,
              body: l.emptyBody,
              icon: Icons.notifications_none_outlined,
              compact: true,
            )
          : Column(
              children: [
                for (final (alert, name) in shown)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          name.isEmpty ? alert.patientId : name,
                          style: theme.textTheme.labelLarge,
                        ),
                        AlertCard(
                          alert: alert,
                          onTap: alert.acknowledged
                              ? null
                              : () => onRespond(alert),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// One patient, shown to the extent §4.3 allows.
///
/// The gate is [ConsentLevel]'s declaration order, which runs from least to most
/// permissive — `alertsOnly < basic < full < guardian`. That ordering is
/// load-bearing here, and the enum's own doc says so.
///
/// Nothing is silently withheld: whatever the tier is, the card says which tier
/// it is and what that tier covers. A relative who can only see alerts should
/// know that is a decision the patient made, not an app that is failing to load.
class _PatientCardScreen extends StatefulWidget {
  const _PatientCardScreen({required this.row});

  final _Row row;

  @override
  State<_PatientCardScreen> createState() => _PatientCardScreenState();
}

class _PatientCardScreenState extends State<_PatientCardScreen> {
  bool _loading = true;
  Failure? _failure;
  List<SeizureLog> _seizures = const [];
  List<Medication> _meds = const [];

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final pid = widget.row.profile.patientId;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      // Only fetched when the tier allows showing it. Reading rows the relative
      // may not see and then hiding them in the widget tree would put the data
      // one debug build away from being visible.
      final level = app.care.levelFor(app.auth.currentUser?.uid ?? '');
      final full = level.index >= ConsentLevel.full.index;
      final seizures = full
          ? await app.db.seizureLogsFor(pid, limit: 20)
          : const <SeizureLog>[];
      final meds = full
          ? await app.medication.forPatient(pid, activeOnly: true)
          : const <Medication>[];
      if (!mounted) return;
      setState(() {
        _seizures = seizures;
        _meds = meds;
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

  Future<void> _acknowledge(String id) async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    try {
      await app.acknowledgeAlert(id);
      if (!mounted) return;
      AppSnack.success(
        context,
        app.apiOnline ? l.acknowledged : l.savedLocallyWillSync,
      );
    } catch (_) {
      if (!mounted) return;
      AppSnack.error(context, l.errUnknown);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final row = widget.row;
    final level = app.care.levelFor(app.auth.currentUser?.uid ?? '');
    final canSeeStatus = level.index >= ConsentLevel.basic.index;
    final canSeeRecord = level.index >= ConsentLevel.full.index;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          row.profile.name.isEmpty ? l.patientLabel : row.profile.name,
        ),
        actions: [
          IconButton(
            tooltip: l.refresh,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AsyncView<bool>(
        loading: _loading,
        failure: _failure,
        value: true,
        onRetry: _load,
        builder: (context, _) => RefreshIndicator(
          onRefresh: _load,
          child: ResponsiveContent(
            maxWidth: 850,
            child: ListView(
              padding: Insets.pageBottomSafe,
              children: [
                OfflineBanner(
                  visible: !app.apiOnline,
                  mode: app.operatingMode,
                  onSyncNow: app.syncNow,
                  lastUpdateLabel: app.care.lastSyncedAt == null
                      ? null
                      : TimeAgo.since(app.care.lastSyncedAt, l),
                  pendingCount: app.care.pendingCount,
                ),
                SectionCard(
                  title: l.isArabic
                      ? 'مستوى العرض المحلي'
                      : 'Local display level',
                  icon: Icons.verified_user_outlined,
                  trailing: RiskBadge(
                    view: RiskView.unknown,
                    labelOverride: consentLevelLabel(level, l),
                    dense: true,
                  ),
                  child: InfoNote(
                    text: l.isArabic
                        ? 'هذا ما يعرضه التطبيق لك. ما يمكنك رؤيته فعلاً يحدده المريض من إعدادات المشاركة.'
                        : 'This is what the app shows you. What you can actually see is set by the patient in their sharing settings.',
                  ),
                ),
                if (canSeeStatus) ...[
                  Gap.vMd,
                  RiskGauge(
                    view: row.view,
                    freshnessLabel:
                        '${l.lastUpdate}: ${TimeAgo.since(row.observedAt, l)}',
                    reasonLabel: l.riskUnknownWhy,
                  ),
                  Gap.vMd,
                  _DeviceRow(app: app),
                ],
                Gap.vMd,
                SectionCard(
                  title: l.alertsTitle,
                  icon: Icons.notifications_none_outlined,
                  child: AlertsList(
                    alerts: row.alerts,
                    onAcknowledge: _acknowledge,
                    onOpen: (a) => Navigator.pushNamed(
                      context,
                      Routes.familyRespond,
                      arguments: PatientRouteArgs(
                        patientId: a.patientId,
                        alertId: a.id,
                      ),
                    ),
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                  ),
                ),
                if (canSeeRecord) ...[
                  Gap.vMd,
                  SectionCard(
                    title: l.seizureHistory,
                    icon: Icons.history_outlined,
                    trailing: Text(
                      '${_seizures.length}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    child: _seizures.isEmpty
                        ? EmptyState(
                            title: l.noHistoryYet,
                            icon: Icons.history_outlined,
                            compact: true,
                          )
                        : Column(
                            children: [
                              for (final s in _seizures.take(10))
                                LabeledValue(
                                  label: TimeAgo.stamp(
                                    s.occurredAt,
                                    AppLocalizations.of(context),
                                  ),
                                  value: s.notes.isEmpty
                                      ? l.noteLabel
                                      : s.notes,
                                  icon: Icons.bolt_outlined,
                                ),
                            ],
                          ),
                  ),
                  Gap.vMd,
                  SectionCard(
                    title: l.medsTitle,
                    icon: Icons.medication_outlined,
                    child: _meds.isEmpty
                        ? EmptyState(
                            title: l.noMedsYet,
                            icon: Icons.medication_outlined,
                            compact: true,
                          )
                        : Column(
                            children: [
                              for (final m in _meds)
                                LabeledValue(
                                  label: m.name,
                                  value: m.dosage.isEmpty ? l.notSet : m.dosage,
                                  icon: Icons.medication_liquid_outlined,
                                ),
                            ],
                          ),
                  ),
                ],
                if (level == ConsentLevel.guardian) ...[
                  Gap.vMd,
                  // Stated rather than implemented. §4.3's guardian tier carries
                  // edit rights; nothing in this build lets a relative change a
                  // patient's record, and a card that implied otherwise would be
                  // worse than one that admits the gap.
                  InfoNote(
                    text: l.comingSoon,
                    icon: Icons.edit_outlined,
                    view: RiskView.caution,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Device state for the selected patient. Valid because the list selects the
/// patient before pushing this screen, so `monitoring` is pointed at them.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final m = app.monitoring;
    final lastSeen = DateTime.tryParse(m.lastDeviceSeen ?? '');
    return SectionCard(
      title: l.deviceSection,
      icon: Icons.sensors,
      trailing: RiskBadge(
        view: m.deviceConnected ? RiskView.safe : RiskView.unknown,
        labelOverride: m.deviceConnected ? l.deviceConnected : l.unknown,
        dense: true,
      ),
      child: LabeledValue(
        label: l.lastUpdate,
        value: TimeAgo.since(lastSeen, l),
        icon: Icons.schedule,
      ),
    );
  }
}

class _CaregiverLocationTrackerCard extends StatelessWidget {
  const _CaregiverLocationTrackerCard();
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pid = app.messages.patientId;
    final profile = pid == null ? null : app.auth.patientById(pid);
    if (profile == null) return const SizedBox.shrink();
    return PatientLocationCard(
      key: ValueKey(pid),
      patientId: pid!,
      patientName: profile.name,
    );
  }
}
