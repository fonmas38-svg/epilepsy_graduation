import 'patient_file_screen.dart';
import '../shared/account_screen.dart';
import '../shared/clinical_messages_screen.dart';
import 'adjudication_screen.dart';
import 'dart:math';
import '../../core/ui/workspace_scaffold.dart';
import 'package:flutter/material.dart';
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
import '../../core/utils/time_ago.dart';
import '../../core/utils/username_generator.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../widgets/metrics_panel.dart';
import '../shared/alerts_list.dart';
import 'package:uuid/uuid.dart';

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
  /// Bottom-bar tab. Tabs switch in place (like the patient's), instead of
  /// pushing a page that hides the bar and strands the doctor.
  int _tab = 0;
  final _search = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  Failure? _failure;
  List<_Row> _rows = const [];
  _Sort _sort = _Sort.attention;
  final Set<_Filter> _filters = {};
  String? _selectedPatient;
  bool _showTwoPane = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _search.dispose();
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
        includeCare: true,
      );
      if (!current()) return;
      final rows = <_Row>[];
      for (final p in patients) {
        final assessment = snapshot.latest[p.patientId];
        final alerts = snapshot.alerts[p.patientId] ?? <AlertItem>[];
        // Same rule as the adjudication queue (§5.4): informational alerts are
        // never pending, and an unrecognised severity is.
        final pending = alerts
            .where(
              (a) =>
                  !snapshot.reviewed.contains('${p.patientId}::${a.id}') &&
                  alertRiskView(a.severity) != RiskView.safe,
            )
            .length;
        rows.add(
          _Row(
            profile: p,
            latest: assessment,
            alerts: alerts,
            pendingAdjudications: pending,
            adherence: app.medication.adherenceFromSnapshot(
              snapshot.medications[p.patientId] ?? [],
              snapshot.logs[p.patientId] ?? [],
            ),
          ),
        );
      }
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
    await app.refreshFromCloud();
    await _load();
  }

  Future<void> _showAddPatientDialog() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AddPatientDialog(),
    );
    if (ok == true) {
      await _load();
    }
  }

  /// Select, then open. The file screen loads that patient's notes and consents,
  /// and both are per-patient state on `CareService`.
  Future<void> _open(_Row row) async {
    if (_showTwoPane) {
      setState(() => _selectedPatient = row.profile.patientId);
      return;
    }
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
          _Filter.lowAdherence => (r.adherence ?? 1) < _lowAdherence,
        };
        // Filters are additive: every selected one must hold, otherwise
        // selecting two of them would widen the list instead of narrowing it.
        if (!match) return false;
      }
      return true;
    }).toList();
    out.sort(
      (a, b) => switch (_sort) {
        _Sort.name => a.profile.name.compareTo(b.profile.name),
        _Sort.attention => b.attentionScore.compareTo(a.attentionScore),
      },
    );
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final rows = _visible();
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _tab != 0) setState(() => _tab = 0);
      },
      child: WorkspaceScaffold(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        // Other tabs bring their own app bar.
        appBar: _tab != 0
            ? null
            : AppBar(
                title: Text(l.isArabic ? 'المرضى' : 'Patients'),
                actions: [
                  IconButton(
                    tooltip: l.isArabic ? 'إضافة مريض جديد' : 'Add new patient',
                    onPressed: _busy ? null : () => _showAddPatientDialog(),
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                  ),
                  IconButton(
                    tooltip: l.refresh,
                    onPressed: _loading || _busy ? null : _refresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
        body: IndexedStack(
          index: _tab,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                _showTwoPane = constraints.maxWidth >= 900;
                final list = AsyncView<List<_Row>>(
                  loading: _loading,
                  failure: _failure,
                  value: _rows,
                  isEmpty: (v) => v.isEmpty,
                  onRetry: _load,
                  emptyTitle: l.noPatientsYet,
                  emptyBody: l.isArabic
                      ? 'يمكنك إضافة مريضك الأول الآن للبدء بمتابعة حالته السريرية وإشاراته الحيوية.'
                      : 'Add your first patient to start following their clinical status and vital signals.',
                  emptyIcon: Icons.people_outline,
                  builder: (context, _) => RefreshIndicator(
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
                            // Null when never synced: the banner then says so,
                            // instead of «last update Not set».
                            lastUpdateLabel: app.care.lastSyncedAt == null
                                ? null
                                : TimeAgo.since(app.care.lastSyncedAt, l),
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
                                ? EmptyState(
                                    title: l.emptyTitle,
                                    body: l.emptyBody,
                                    icon: Icons.filter_alt_off_outlined,
                                    compact: true,
                                  )
                                : Column(
                                    children: [
                                      for (var i = 0; i < rows.length; i++)
                                        _PatientTile(
                                          row: rows[i],
                                          enabled: !_busy,
                                          onOpen: () => _open(rows[i]),
                                          // A divider separates rows; none after
                                          // the last one.
                                          last: i == rows.length - 1,
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
                if (constraints.maxWidth < 900) return list;
                return Row(
                  children: [
                    SizedBox(
                      width: (constraints.maxWidth * .38).clamp(330.0, 500.0),
                      child: list,
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: _selectedPatient == null
                          ? Center(
                              child: Text(
                                l.isArabic
                                    ? 'اختر مريضاً لعرض ملفه'
                                    : 'Select a patient to view their file',
                              ),
                            )
                          : PatientFileScreen(
                              key: ValueKey(_selectedPatient),
                              embedded: true,
                              args: PatientRouteArgs(
                                patientId: _selectedPatient!,
                              ),
                            ),
                    ),
                  ],
                );
              },
            ),
            const AdjudicationScreen(),
            const ClinicalMessagesScreen(),
            const AccountScreen(embedded: true),
          ],
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
    this.last = false,
  });

  final _Row row;
  final bool enabled;
  final VoidCallback onOpen;
  final bool last;

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
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.profile.name.isEmpty
                        ? row.profile.patientId
                        : row.profile.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Gap.vXs,
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
                    value: row.adherence == null
                        ? l.notSet
                        : '${(row.adherence! * 100).round()}%',
                    alert: (row.adherence ?? 1) < _lowAdherence,
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
              if (!last) const Divider(height: Gap.sm),
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
  final double? adherence;

  bool get hasAssessment =>
      latest != null &&
      latest!.confidence > 0 &&
      latest!.features['assessment_valid'] != false;

  RiskLabel? get label => hasAssessment ? latest!.label : null;

  DateTime? get observedAt => hasAssessment ? latest!.timestamp : null;

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
    dataAvailable:
        latest != null &&
        latest!.confidence > 0 &&
        latest!.features['assessment_valid'] != false,
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
    if ((adherence ?? 1) < _lowAdherence) score += 30;
    return score;
  }
}

class AddPatientDialog extends StatefulWidget {
  const AddPatientDialog({super.key});

  @override
  State<AddPatientDialog> createState() => _AddPatientDialogState();
}

class _AddPatientDialogState extends State<AddPatientDialog> {
  bool get _ar => Localizations.localeOf(context).languageCode == 'ar';

  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _emergencyContactCtrl = TextEditingController();
  final _diagnosisCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  String? _gender;

  bool _addCaregiver = false;
  final _cgNameCtrl = TextEditingController();
  final _cgUsernameCtrl = TextEditingController();
  final _cgPhoneCtrl = TextEditingController();
  final _cgPasswordCtrl = TextEditingController();
  String _cgRelation = 'أب / ولي أمر';

  bool _usernameEditedManually = false;
  bool _cgUsernameEditedManually = false;
  late final String _idempotencyKey = Uuid().v4();

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(_onPatientNameChanged);
    _cgNameCtrl.addListener(_onCaregiverNameChanged);
  }

  void _onPatientNameChanged() {
    if (_usernameEditedManually || _busy) return;
    final generated = UsernameGenerator.generate(_nameCtrl.text, prefix: 'pat');
    if (generated.isNotEmpty) {
      _usernameCtrl.value = TextEditingValue(
        text: generated,
        selection: TextSelection.collapsed(offset: generated.length),
      );
      if (!_cgUsernameEditedManually && _cgNameCtrl.text.trim().isEmpty) {
        final cgGen = 'cg_$generated';
        _cgUsernameCtrl.value = TextEditingValue(
          text: cgGen,
          selection: TextSelection.collapsed(offset: cgGen.length),
        );
      }
    }
  }

  void _onCaregiverNameChanged() {
    if (_cgUsernameEditedManually || _busy) return;
    final generated = UsernameGenerator.generate(
      _cgNameCtrl.text,
      prefix: 'cg',
    );
    if (generated.isNotEmpty) {
      _cgUsernameCtrl.value = TextEditingValue(
        text: generated,
        selection: TextSelection.collapsed(offset: generated.length),
      );
    }
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_onPatientNameChanged);
    _cgNameCtrl.removeListener(_onCaregiverNameChanged);
    _nameCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _ageCtrl.dispose();
    _emergencyContactCtrl.dispose();
    _diagnosisCtrl.dispose();
    _notesCtrl.dispose();
    _cgNameCtrl.dispose();
    _cgUsernameCtrl.dispose();
    _cgPhoneCtrl.dispose();
    _cgPasswordCtrl.dispose();
    super.dispose();
  }

  String _newPassword() {
    const alphabet =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#';
    final random = Random.secure();
    return List.generate(
      20,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  String? _validatePassword(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    return text.length < 6 || text.length > 128
        ? 'استخدم من 6 إلى 128 حرفًا، أو اترك الحقل فارغًا للتوليد الآمن'
        : null;
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final app = context.read<AppState>();
    final patUser = _usernameCtrl.text.trim().toLowerCase();
    final cgUser = _cgUsernameCtrl.text.trim().isNotEmpty
        ? _cgUsernameCtrl.text.trim().toLowerCase()
        : 'cg_$patUser';
    final generatedPatientPass = _passwordCtrl.text.trim().isEmpty
        ? _newPassword()
        : _passwordCtrl.text.trim();
    final generatedCgPass = _addCaregiver && _cgPasswordCtrl.text.trim().isEmpty
        ? _newPassword()
        : _cgPasswordCtrl.text.trim();

    try {
      app.setPendingPatientMetadata(
        email: _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
        gender: _gender,
        emergencyContact: _emergencyContactCtrl.text.trim().isEmpty
            ? null
            : _emergencyContactCtrl.text.trim(),
        idempotencyKey: _idempotencyKey,
      );
      final profile = await app.createDoctorPatient(
        name: _nameCtrl.text.trim(),
        username: patUser,
        password: generatedPatientPass,
        phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
        age: int.tryParse(_ageCtrl.text.trim()),
        diagnosis: _diagnosisCtrl.text.trim(),
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        caregiverName: _addCaregiver && _cgNameCtrl.text.trim().isNotEmpty
            ? _cgNameCtrl.text.trim()
            : null,
        caregiverUsername: _addCaregiver ? cgUser : null,
        caregiverPhone: _addCaregiver && _cgPhoneCtrl.text.trim().isNotEmpty
            ? _cgPhoneCtrl.text.trim()
            : null,
        caregiverRelation: _addCaregiver ? _cgRelation : null,
        caregiverPassword: _addCaregiver ? generatedCgPass : null,
      );

      if (!mounted) return;
      // Keep the form mounted until the credentials have been acknowledged.
      setState(() => _busy = false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                color: AppColors.accent(ctx, AccentTone.green).foreground,
                size: 28,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  (_ar ? 'تم إنشاء ملف المريض بنجاح' : 'Patient file created'),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (_ar
                      ? 'المريض: ${profile.name}'
                      : 'Patient: ${profile.name}'),
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 4),
                Text((_ar ? 'اسم المستخدم: $patUser' : 'Username: $patUser')),
                Text(
                  (_ar
                      ? 'كلمة المرور: $generatedPatientPass'
                      : 'Password: $generatedPatientPass'),
                ),
                if (_addCaregiver && _cgNameCtrl.text.trim().isNotEmpty) ...[
                  Divider(height: 24),
                  Text(
                    (_ar
                        ? 'المرافق الأسري: ${_cgNameCtrl.text.trim()} ($_cgRelation)'
                        : 'Caregiver: ${_cgNameCtrl.text.trim()} ($_cgRelation)'),
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text((_ar ? 'اسم المستخدم: $cgUser' : 'Username: $cgUser')),
                  Text(
                    (_ar
                        ? 'كلمة المرور: $generatedCgPass'
                        : 'Password: $generatedCgPass'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text((_ar ? 'تم' : 'Done')),
            ),
          ],
        ),
      );
      if (mounted && Navigator.canPop(context)) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          final failure = Failure.from(e);
          _error = failure.kind == FailureKind.timeout
              ? 'تأخر رد الخادم. قد يكون الحساب أُنشئ؛ حدّث قائمة المرضى وتحقق من اسم المستخدم قبل إعادة الإنشاء.'
              : failure.message(AppLocalizations.of(context));
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 540),
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.person_add_alt_1_rounded,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (_ar ? 'إضافة مريض' : 'Add patient'),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              (_ar
                                  ? 'أنشئ حساب المريض واربطه بعيادتك.'
                                  : 'Create the patient account and link it to your clinic.'),
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Divider(height: 24),
                  if (_error != null) ...[
                    Semantics(
                      liveRegion: true,
                      child: Container(
                        padding: EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: 12),
                  ],

                  // Patient Section
                  Text(
                    (_ar
                        ? 'البيانات الأساسية للمريض (مطلوبة)'
                        : 'Patient basics (required)'),
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  SizedBox(height: 8),
                  TextFormField(
                    controller: _nameCtrl,
                    decoration: InputDecoration(
                      labelText: (_ar
                          ? 'اسم المريض الكامل *'
                          : 'Patient full name *'),
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'يرجى إدخال اسم المريض'
                        : null,
                  ),
                  SizedBox(height: 10),
                  TextFormField(
                    controller: _usernameCtrl,
                    onChanged: (_) => _usernameEditedManually = true,
                    decoration: InputDecoration(
                      labelText: (_ar ? 'اسم المستخدم *' : 'Username *'),
                      prefixIcon: Icon(Icons.badge_outlined),
                      hintText: 'pat_ahmed',
                      helperText: (_ar
                          ? 'يُولّد تلقائياً من الاسم ويمكنك تعديله لتسجيل الدخول.'
                          : 'Generated from the name; you can edit it.'),
                    ),
                    validator: (v) => (v == null || v.trim().length < 3)
                        ? 'اسم المستخدم يجب ألا يقل عن 3 أحرف'
                        : null,
                  ),
                  SizedBox(height: 10),
                  TextFormField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: (_ar
                          ? 'البريد الإلكتروني للمريض (اختياري)'
                          : 'Patient email (optional)'),
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                  ),
                  SizedBox(height: 10),
                  TextFormField(
                    controller: _passwordCtrl,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    validator: _validatePassword,
                    decoration: InputDecoration(
                      labelText: (_ar
                          ? 'كلمة مرور المريض (اختيارية)'
                          : 'Patient password (optional)'),
                      helperText: (_ar
                          ? '6–128 حرفًا. اتركها فارغة لتوليد كلمة مرور آمنة.'
                          : '6–128 characters. Leave empty to generate a secure one.'),
                      helperMaxLines: 2,
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  SizedBox(height: 16),

                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      (_ar
                          ? 'بيانات المريض المطلوبة'
                          : 'Required patient details'),
                    ),
                    initiallyExpanded: true,
                    maintainState: true,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: _gender,
                        decoration: InputDecoration(
                          labelText: (_ar ? 'الجنس *' : 'Sex *'),
                        ),
                        items: [
                          DropdownMenuItem(value: 'male', child: Text('ذكر')),
                          DropdownMenuItem(
                            value: 'female',
                            child: Text((_ar ? 'أنثى' : 'Female')),
                          ),
                        ],
                        validator: (v) => v == null ? 'اختر الجنس' : null,
                        onChanged: _busy
                            ? null
                            : (value) => setState(() => _gender = value),
                      ),
                      SizedBox(height: 10),
                      TextFormField(
                        controller: _emergencyContactCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: (_ar
                              ? 'رقم اتصال الطوارئ *'
                              : 'Emergency contact number *'),
                        ),
                        validator: (v) =>
                            RegExp(
                              r'^\+?[0-9]{8,15}$',
                            ).hasMatch(v?.trim() ?? '')
                            ? null
                            : (_ar
                                  ? 'أدخل رقم اتصال طوارئ صالحاً'
                                  : 'Enter a valid emergency number'),
                      ),
                      SizedBox(height: 10),
                      Column(
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: TextFormField(
                              controller: _phoneCtrl,
                              validator: (v) =>
                                  RegExp(
                                    r'^\+?[0-9]{8,15}$',
                                  ).hasMatch(v?.trim() ?? '')
                                  ? null
                                  : (_ar
                                        ? 'أدخل رقم هاتف من 8 إلى 15 رقماً'
                                        : 'Enter a phone number of 8 to 15 digits'),
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                labelText: (_ar
                                    ? 'رقم هاتف المريض'
                                    : 'Patient phone'),
                                prefixIcon: Icon(Icons.phone_outlined),
                              ),
                            ),
                          ),
                          SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: TextFormField(
                              controller: _ageCtrl,
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return (_ar
                                      ? 'العمر مطلوب'
                                      : 'Age is required');
                                }
                                final age = int.tryParse(value.trim());
                                return age == null || age < 0 || age > 130
                                    ? 'أدخل عمرًا من 0 إلى 130'
                                    : null;
                              },
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: (_ar ? 'العمر' : 'Age'),
                                prefixIcon: Icon(Icons.cake_outlined),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 10),
                      TextFormField(
                        controller: _diagnosisCtrl,
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'التشخيص مطلوب'
                            : null,
                        decoration: InputDecoration(
                          labelText: (_ar
                              ? 'التشخيص ونوع الصرع'
                              : 'Diagnosis and epilepsy type'),
                          prefixIcon: Icon(Icons.medical_information_outlined),
                        ),
                      ),
                      SizedBox(height: 10),
                      TextFormField(
                        controller: _notesCtrl,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: (_ar
                              ? 'ملاحظات وتوجيهات سريرية أولية'
                              : 'Initial clinical notes'),
                          prefixIcon: Icon(Icons.notes_outlined),
                        ),
                      ),
                      SizedBox(height: 16),
                    ],
                  ),

                  // Optional Family Caregiver Section
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _addCaregiver
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                      ),
                    ),
                    padding: EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _addCaregiver,
                          onChanged: (v) =>
                              setState(() => _addCaregiver = v ?? false),
                          title: Text(
                            (_ar
                                ? 'إنشاء حساب مرافق'
                                : 'Create a caregiver account'),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            (_ar
                                ? 'اختياري؛ يُربط الحساب بهذا المريض.'
                                : 'Optional; linked to this patient.'),
                            style: TextStyle(fontSize: 12),
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        if (_addCaregiver) ...[
                          SizedBox(height: 8),
                          TextFormField(
                            controller: _cgNameCtrl,
                            validator: (value) =>
                                _addCaregiver &&
                                    (value == null || value.trim().isEmpty)
                                ? 'أدخل اسم المرافق أو ألغِ إضافته'
                                : null,
                            decoration: InputDecoration(
                              labelText: (_ar
                                  ? 'اسم المرافق الكامل'
                                  : 'Caregiver full name'),
                              prefixIcon: Icon(Icons.family_restroom_outlined),
                            ),
                          ),
                          SizedBox(height: 10),
                          TextFormField(
                            controller: _cgUsernameCtrl,
                            onChanged: (_) => _cgUsernameEditedManually = true,
                            decoration: InputDecoration(
                              labelText: (_ar
                                  ? 'اسم مستخدم المرافق'
                                  : 'Caregiver username'),
                              helperText: (_ar
                                  ? 'يُولّد تلقائياً من اسم المرافق ويمكنك تعديله.'
                                  : 'Generated from the caregiver name; you can edit it.'),
                              prefixIcon: Icon(Icons.badge_outlined),
                            ),
                          ),
                          SizedBox(height: 10),
                          Column(
                            children: [
                              SizedBox(
                                width: double.infinity,
                                child: TextFormField(
                                  controller: _cgPhoneCtrl,
                                  keyboardType: TextInputType.phone,
                                  decoration: InputDecoration(
                                    labelText: (_ar
                                        ? 'رقم هاتف المرافق'
                                        : 'Caregiver phone'),
                                    prefixIcon: Icon(Icons.phone_outlined),
                                  ),
                                ),
                              ),
                              SizedBox(height: 10),
                              DropdownButton<String>(
                                isExpanded: true,
                                value: _cgRelation,
                                onChanged: (v) => setState(
                                  () => _cgRelation = v ?? _cgRelation,
                                ),
                                items: [
                                  DropdownMenuItem(
                                    value: 'أب / ولي أمر',
                                    child: Text(
                                      (_ar
                                          ? 'أب / ولي أمر'
                                          : 'Father / guardian'),
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: 'أم',
                                    child: Text((_ar ? 'أم' : 'Mother')),
                                  ),
                                  DropdownMenuItem(
                                    value: 'أخ / أخت',
                                    child: Text((_ar ? 'أخ / أخت' : 'Sibling')),
                                  ),
                                  DropdownMenuItem(
                                    value: 'زوج / زوجة',
                                    child: Text(
                                      (_ar ? 'زوج / زوجة' : 'Spouse'),
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: 'مرافق قانوني',
                                    child: Text(
                                      (_ar ? 'مرافق قانوني' : 'Legal guardian'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          SizedBox(height: 10),
                          TextFormField(
                            controller: _cgPasswordCtrl,
                            obscureText: true,
                            enableSuggestions: false,
                            autocorrect: false,
                            validator: _validatePassword,
                            decoration: InputDecoration(
                              labelText: (_ar
                                  ? 'كلمة مرور المرافق (اختيارية)'
                                  : 'Caregiver password (optional)'),
                              helperText: (_ar
                                  ? '6–128 حرفًا، أو اتركها للتوليد الآمن.'
                                  : '6–128 characters, or leave empty to generate.'),
                              helperMaxLines: 2,
                              prefixIcon: Icon(Icons.lock_outline),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(height: 24),

                  // Actions
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    spacing: 12,
                    overflowSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => Navigator.pop(context, false),
                        child: Text((_ar ? 'إلغاء' : 'Cancel')),
                      ),
                      FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: _busy
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(Icons.check, size: 18),
                        label: Text(
                          _busy ? 'جارٍ الإنشاء...' : 'حفظ وإنشاء السجل',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
