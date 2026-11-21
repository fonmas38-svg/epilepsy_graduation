import 'dart:math';
import '../../core/ui/workspace_scaffold.dart';
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
    try {
      final rows = <_Row>[];
      for (final p in app.auth.accessiblePatients()) {
        final assessments = await app.db.assessmentsFor(p.patientId, limit: 1);
        final alerts = await app.db.alertsFor(p.patientId, limit: 100);
        final decided = await app.db.adjudicatedAlertIds(p.patientId);
        // Same rule as the adjudication queue (§5.4): informational alerts are
        // never pending, and an unrecognised severity is.
        final pending = alerts
            .where(
              (a) =>
                  !decided.contains(a.id) &&
                  alertRiskView(a.severity) != RiskView.safe,
            )
            .length;
        rows.add(
          _Row(
            profile: p,
            latest: assessments.isEmpty ? null : assessments.first,
            alerts: alerts,
            pendingAdjudications: pending,
            adherence: await app.medication.adherence(p.patientId),
          ),
        );
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
      canPop: true,
      child: WorkspaceScaffold(
        appBar: AppBar(
          title: Text(l.isArabic ? 'المرضى' : 'Patients'),
          actions: [
            IconButton(
              tooltip: 'إضافة مريض جديد',
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
        body: AsyncView<List<_Row>>(
          loading: _loading,
          failure: _failure,
          value: _rows,
          isEmpty: (v) => v.isEmpty,
          onRetry: _load,
          emptyTitle: l.noPatientsYet,
          emptyBody:
              'يمكنك إضافة مريضك الأول الآن للبدء بمتابعة حالته السريرية وإشاراته الحيوية',
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

class AddPatientDialog extends StatefulWidget {
  const AddPatientDialog({super.key});

  @override
  State<AddPatientDialog> createState() => _AddPatientDialogState();
}

class _AddPatientDialogState extends State<AddPatientDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _diagnosisCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  bool _addCaregiver = false;
  final _cgNameCtrl = TextEditingController();
  final _cgPhoneCtrl = TextEditingController();
  final _cgPasswordCtrl = TextEditingController();
  String _cgRelation = 'أب / ولي أمر';

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _phoneCtrl.dispose();
    _ageCtrl.dispose();
    _diagnosisCtrl.dispose();
    _notesCtrl.dispose();
    _cgNameCtrl.dispose();
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
    final generatedPatientPass = _passwordCtrl.text.trim().isEmpty
        ? _newPassword()
        : _passwordCtrl.text.trim();
    final generatedCgPass = _addCaregiver && _cgPasswordCtrl.text.trim().isEmpty
        ? _newPassword()
        : _cgPasswordCtrl.text.trim();

    try {
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
        caregiverUsername: _addCaregiver ? 'cg_$patUser' : null,
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
          title: const Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.green, size: 28),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'تم إنشاء ملف المريض بنجاح',
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
                  'المريض: ${profile.name}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text('اسم المستخدم: $patUser'),
                Text('كلمة المرور: $generatedPatientPass'),
                if (_addCaregiver && _cgNameCtrl.text.trim().isNotEmpty) ...[
                  const Divider(height: 24),
                  Text(
                    'المرافق الأسري: ${_cgNameCtrl.text.trim()} ($_cgRelation)',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text('اسم المستخدم: cg_$patUser'),
                  Text('كلمة المرور: $generatedCgPass'),
                ],
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('تم'),
            ),
          ],
        ),
      );
      if (mounted) Navigator.pop(context, true);
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
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Padding(
          padding: const EdgeInsets.all(20),
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
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.person_add_alt_1_rounded,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'إضافة مريض',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'أنشئ حساب المريض واربطه بعيادتك.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  if (_error != null) ...[
                    Semantics(
                      liveRegion: true,
                      child: Container(
                        padding: const EdgeInsets.all(10),
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
                    const SizedBox(height: 12),
                  ],

                  // Patient Section
                  const Text(
                    'البيانات الأساسية للمريض (مطلوبة)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'اسم المريض الكامل *',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'يرجى إدخال اسم المريض'
                        : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _usernameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'اسم المستخدم *',
                      prefixIcon: Icon(Icons.badge_outlined),
                      hintText: 'patient_ahmed',
                      helperText: 'يستخدمه المريض لتسجيل الدخول.',
                    ),
                    validator: (v) => (v == null || v.trim().length < 3)
                        ? 'اسم المستخدم يجب ألا يقل عن 3 أحرف'
                        : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _passwordCtrl,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    validator: _validatePassword,
                    decoration: const InputDecoration(
                      labelText: 'كلمة مرور المريض (اختيارية)',
                      helperText:
                          '6–128 حرفًا. اتركها فارغة لتوليد كلمة مرور آمنة.',
                      helperMaxLines: 2,
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 16),

                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('معلومات طبية واتصال'),
                    subtitle: const Text('اختيارية'),
                    maintainState: true,
                    children: [
                      Column(
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: TextFormField(
                              controller: _phoneCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                labelText: 'رقم هاتف المريض',
                                prefixIcon: Icon(Icons.phone_outlined),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: TextFormField(
                              controller: _ageCtrl,
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return null;
                                }
                                final age = int.tryParse(value.trim());
                                return age == null || age < 0 || age > 130
                                    ? 'أدخل عمرًا من 0 إلى 130'
                                    : null;
                              },
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'العمر',
                                prefixIcon: Icon(Icons.cake_outlined),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _diagnosisCtrl,
                        decoration: const InputDecoration(
                          labelText: 'التشخيص ونوع الصرع',
                          prefixIcon: Icon(Icons.medical_information_outlined),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _notesCtrl,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'ملاحظات وتوجيهات سريرية أولية',
                          prefixIcon: Icon(Icons.notes_outlined),
                        ),
                      ),
                      const SizedBox(height: 16),
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
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _addCaregiver,
                          onChanged: (v) =>
                              setState(() => _addCaregiver = v ?? false),
                          title: const Text(
                            'إنشاء حساب مرافق',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: const Text(
                            'اختياري؛ يُربط الحساب بهذا المريض.',
                            style: TextStyle(fontSize: 12),
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        if (_addCaregiver) ...[
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _cgNameCtrl,
                            validator: (value) =>
                                _addCaregiver &&
                                    (value == null || value.trim().isEmpty)
                                ? 'أدخل اسم المرافق أو ألغِ إضافته'
                                : null,
                            decoration: const InputDecoration(
                              labelText: 'اسم المرافق الكامل',
                              prefixIcon: Icon(Icons.family_restroom_outlined),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Column(
                            children: [
                              SizedBox(
                                width: double.infinity,
                                child: TextFormField(
                                  controller: _cgPhoneCtrl,
                                  keyboardType: TextInputType.phone,
                                  decoration: const InputDecoration(
                                    labelText: 'رقم هاتف المرافق',
                                    prefixIcon: Icon(Icons.phone_outlined),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              DropdownButton<String>(
                                isExpanded: true,
                                value: _cgRelation,
                                onChanged: (v) => setState(
                                  () => _cgRelation = v ?? _cgRelation,
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'أب / ولي أمر',
                                    child: Text('أب / ولي أمر'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'أم',
                                    child: Text('أم'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'أخ / أخت',
                                    child: Text('أخ / أخت'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'زوج / زوجة',
                                    child: Text('زوج / زوجة'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'مرافق قانوني',
                                    child: Text('مرافق قانوني'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _cgPasswordCtrl,
                            obscureText: true,
                            enableSuggestions: false,
                            autocorrect: false,
                            validator: _validatePassword,
                            decoration: const InputDecoration(
                              labelText: 'كلمة مرور المرافق (اختيارية)',
                              helperText:
                                  '6–128 حرفًا، أو اتركها للتوليد الآمن.',
                              helperMaxLines: 2,
                              prefixIcon: Icon(Icons.lock_outline),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

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
                        child: const Text('إلغاء'),
                      ),
                      FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check, size: 18),
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
