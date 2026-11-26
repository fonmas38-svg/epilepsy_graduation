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
import '../patient/medication_screen.dart';
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
/// Local records remain available offline; supported resources refresh from the
/// server. Model operating points are not editable until a validated server
/// contract exists. Nothing here retrains the model.
class PatientFileScreen extends StatefulWidget {
  const PatientFileScreen({super.key, this.args, this.embedded = false});

  final PatientRouteArgs? args;
  final bool embedded;

  @override
  State<PatientFileScreen> createState() => _PatientFileScreenState();
}

class _PatientFileScreenState extends State<PatientFileScreen> {
  final _reports = ReportService();

  bool _loading = true;
  bool _busy = false;
  _FileData? _data;
  Failure? _failure;
  AppUser? _owner;
  String? _origin;
  int? _revision;
  String? _patientId;
  bool _bound = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bound) return;
    final app = context.read<AppState>();
    _owner = app.auth.currentUser;
    _origin = app.api.baseUrl;
    _revision = app.api.tokens.revision;
    _patientId = widget.args?.patientId ?? app.activePatientId;
    _bound = true;
  }

  bool _current(AppState app) =>
      mounted &&
      AppUser.sameSessionOwner(_owner, app.auth.currentUser) &&
      _owner?.role == UserRole.doctor &&
      _origin == app.api.baseUrl &&
      _revision == app.api.tokens.revision &&
      _patientId != null &&
      app.auth.canAccessPatient(_patientId!) &&
      (widget.args != null || _patientId == app.activePatientId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final pid = _patientId;
    bool current() => _current(app);
    setState(() {
      _loading = true;
      _failure = null;
    });
    if (pid == null || !current()) {
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
      if (!current()) return;
      try {
        await app.medication.synchronize(pid);
      } catch (_) {
        /* Retain cached prescriptions offline. */
      }
      if (!current()) return;
      final db = app.db;
      final readings = await db.recentReadings(
        pid,
        limit: 1,
        serverOrigin: app.dataOrigin,
      );
      // Load prescriptions and triggers from API (best-effort).
      List<Map<String, dynamic>> prescriptions = [];
      List<Map<String, dynamic>> triggers = [];
      // «Not loaded» is not «none»: offline, an empty list would tell the
      // doctor the patient has no prescriptions or triggers.
      var serverListsLoaded = false;
      if (app.apiOnline) {
        try {
          prescriptions = await app.api.getDoctorPrescriptions(pid);
          triggers = await app.api.getDoctorPatientTriggers(pid);
          serverListsLoaded = true;
        } catch (_) {}
      }
      List<ClinicalNote> notes = const [];
      try {
        notes = await app.care.clinicalNotesFor(
          pid,
          refreshRemote: app.apiOnline,
        );
      } catch (e) {
        final f = Failure.from(e);
        if (f.kind != FailureKind.notFound && !f.isConnectivity) rethrow;
        notes = await app.care.clinicalNotesFor(pid, refreshRemote: false);
      }
      final data = _FileData(
        patientId: pid,
        profile: app.auth.patientById(pid),
        assessments: await db.assessmentsFor(
          pid,
          limit: 200,
          serverOrigin: app.dataOrigin,
        ),
        alerts: await db.alertsFor(
          pid,
          limit: 200,
          serverOrigin: app.dataOrigin,
        ),
        seizures: await db.seizureLogsFor(pid, limit: 200),
        events: await db.predictionEventsFor(
          pid,
          limit: 200,
          serverOrigin: app.dataOrigin,
        ),
        adjudications: await db.adjudicationsFor(pid, limit: 200),
        notes: notes,
        reading: readings.isEmpty ? null : readings.first,
        adherence: await app.medication.adherenceIfDue(pid),
        activeMeds: (await app.medication.forPatient(
          pid,
          activeOnly: true,
        )).length,
        prescriptions: prescriptions,
        triggers: triggers,
        serverListsLoaded: serverListsLoaded,
      );
      if (!current()) return;
      setState(() {
        _data = data;
        _loading = false;
      });
      await _logAccess(app);
    } catch (e) {
      if (!current()) return;
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
    final owner = _owner;
    bool current() => _current(app) && d.patientId == _patientId;
    if (!current()) return;
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _NoteSheet(),
    );
    if (text == null || text.trim().isEmpty || !current()) return;
    setState(() => _busy = true);
    try {
      await app.care.addClinicalNote(
        patientId: d.patientId,
        text: text,
        doctorId: owner?.uid ?? '',
      );
      final notes = await app.care.clinicalNotesFor(d.patientId);
      if (!current()) return;
      setState(() {
        _data = d.withNotes(notes);
        _busy = false;
      });
      if (!mounted) return;
      AppSnack.success(context, l.savedLocallyWillSync);
    } catch (_) {
      if (!current()) return;
      setState(() => _busy = false);
      if (!mounted) return;
      AppSnack.error(context, l.errUnknown);
    }
  }

  Future<void> _resetPassword() async {
    final app = context.read<AppState>();
    final pid = _patientId;
    if (!_current(app) || pid == null || _busy) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DoctorPatientPasswordResetDialog(
        patientName: _data?.profile?.name ?? widget.args?.patientName ?? '',
        isCurrent: () => _current(app),
        onSave: (password) async {
          if (!_current(app)) throw const Failure(FailureKind.unauthorized);
          final result = await app.api.sendJson(
            method: 'POST',
            path: '/doctor/patients/${Uri.encodeComponent(pid)}/password',
            body: {'password': password},
          );
          if (!_current(app)) throw const Failure(FailureKind.unauthorized);
          if (result['ok'] != true) {
            throw const FormatException('Password reset was not acknowledged');
          }
        },
      ),
    );
  }

  Future<void> _exportPdf(_FileData d) async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final profile = d.profile;
    if (profile == null || !_current(app) || d.patientId != _patientId) return;
    setState(() => _busy = true);
    try {
      final doc = await _reports.toPdf(
        patient: profile,
        assessments: d.assessments,
        alerts: d.alerts,
      );
      if (!_current(app)) return;
      await Printing.layoutPdf(onLayout: (_) => doc.save());
      if (mounted && _current(app)) AppSnack.success(context, l.reportReady);
    } catch (_) {
      if (mounted && _current(app)) AppSnack.error(context, l.exportFailed);
    } finally {
      if (_current(app)) setState(() => _busy = false);
    }
  }

  Future<void> _exportCsv(_FileData d) async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final profile = d.profile;
    if (profile == null || !_current(app) || d.patientId != _patientId) return;
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
      if (!mounted || !_current(app)) return;
      ok
          ? AppSnack.success(context, l.copied)
          : AppSnack.error(context, l.exportFailed);
    } finally {
      if (_current(app)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final pid = _patientId;
    final ar = Localizations.localeOf(context).languageCode == 'ar';

    if (pid == null) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !widget.embedded,
          title: Text(l.patientFile),
        ),
        body: EmptyState(
          title: l.noPatientSelected,
          body: l.noLinkedPatientsBody,
          icon: Icons.person_search_outlined,
        ),
      );
    }

    if (!_current(app)) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !widget.embedded,
          title: Text(l.patientFile),
        ),
        body: EmptyState(
          title: l.errSessionExpired,
          body: ar
              ? 'أعد فتح ملف المريض من قائمة المرضى.'
              : 'Reopen the patient file from your patient list.',
          icon: Icons.lock_outline,
        ),
      );
    }

    final args = PatientRouteArgs(
      patientId: pid,
      patientName: _data?.profile?.name ?? widget.args?.patientName,
    );
    Future<void> medications() async {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => MedicationScreen(patientId: pid)),
      );
      if (_current(app)) _load();
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text(_data?.profile?.name ?? l.patientFile),
        actions: [
          IconButton(
            tooltip: l.refresh,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('patient-file-actions'),
            tooltip: ar ? 'خدمات المريض' : 'Patient actions',
            onSelected: (action) {
              if (!_current(app)) return;
              if (action == 'password') {
                _resetPassword();
              } else if (action == 'medications') {
                medications();
              } else {
                final route = switch (action) {
                  'messages' => Routes.messages,
                  'reports' => Routes.reports,
                  _ => Routes.doctorAdjudication,
                };
                Navigator.pushNamed(context, route, arguments: args);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'messages',
                child: Text(ar ? 'رسائل المريض' : 'Patient messages'),
              ),
              PopupMenuItem(
                value: 'reports',
                child: Text(ar ? 'تقارير المريض' : 'Patient reports'),
              ),
              PopupMenuItem(
                value: 'medications',
                child: Text(ar ? 'أدوية المريض' : 'Patient medications'),
              ),
              PopupMenuItem(value: 'review', child: Text(l.adjudicationTitle)),
              PopupMenuItem(
                value: 'password',
                enabled: !_busy,
                child: Text(
                  ar ? 'إعادة تعيين كلمة المرور' : 'Reset patient password',
                ),
              ),
            ],
          ),
        ],
      ),
      body: ResponsiveContent(
        maxWidth: 1000,
        child: AsyncView<_FileData>(
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
                  mode: app.operatingMode,
                  onSyncNow: app.syncNow,
                  lastUpdateLabel: app.care.lastSyncedAt == null
                      ? null
                      : TimeAgo.since(app.care.lastSyncedAt, l),
                  pendingCount: app.care.pendingCount,
                ),
                _SummarySection(data: d, onManageMeds: medications),
                Gap.vMd,
                _TimelineSection(data: d),
                Gap.vMd,
                _SignalSection(reading: d.reading),
                Gap.vMd,
                _AnalyticsSection(data: d),
                Gap.vMd,
                // ─── Prescriptions ────────────────────────────────────
                _PrescriptionSection(
                  patientId: d.patientId,
                  prescriptions: d.prescriptions,
                  loaded: d.serverListsLoaded,
                  onRefresh: _load,
                ),
                Gap.vMd,
                // ─── Trigger Diary ────────────────────────────────────
                _TriggersSection(
                  triggers: d.triggers,
                  loaded: d.serverListsLoaded,
                ),
                Gap.vMd,
                _NotesSection(
                  notes: d.notes,
                  enabled: !_busy,
                  onAdd: () => _addNote(d),
                ),
                Gap.vMd,
                const _OperatingPointSection(),
                Gap.vMd,
                _ReportsSection(
                  patientArgs: args,
                  enabled: !_busy && d.profile != null,
                  onPdf: () => _exportPdf(d),
                  onCsv: () => _exportCsv(d),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Explicit passwords keep an uncertain response recoverable: the doctor knows
/// the chosen credential even if the server commits before the connection drops.
class DoctorPatientPasswordResetDialog extends StatefulWidget {
  const DoctorPatientPasswordResetDialog({
    super.key,
    required this.patientName,
    required this.onSave,
    required this.isCurrent,
  });

  final String patientName;
  final Future<void> Function(String password) onSave;
  final bool Function() isCurrent;

  @override
  State<DoctorPatientPasswordResetDialog> createState() =>
      _DoctorPatientPasswordResetDialogState();
}

class _DoctorPatientPasswordResetDialogState
    extends State<DoctorPatientPasswordResetDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _saved = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || _saved || !widget.isCurrent()) return;
    if (!_form.currentState!.validate()) return;
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(_password.text);
      if (!mounted || !widget.isCurrent()) return;
      _password.clear();
      _confirm.clear();
      setState(() => _saved = true);
    } catch (error) {
      if (!mounted || !widget.isCurrent()) return;
      final failure = Failure.from(error);
      setState(
        () => _error =
            failure.isConnectivity || failure.kind == FailureKind.server
            ? (ar
                  ? 'لم نتمكن من تأكيد النتيجة. قد تكون الكلمة قد تغيّرت؛ تحقق مع المريض باستخدام الكلمة التي اخترتها قبل إعادة الطلب.'
                  : 'The result could not be confirmed. The password may have changed; check with the patient using your chosen password before submitting again.')
            : failure.message(AppLocalizations.of(context)),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final valid = widget.isCurrent();
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(ar ? 'إعادة تعيين كلمة المرور' : 'Reset patient password'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: !valid
                ? Text(
                    ar
                        ? 'تغيرت الجلسة. أغلق النافذة وأعد فتح ملف المريض.'
                        : 'The session changed. Close this dialog and reopen the patient file.',
                  )
                : _saved
                ? Semantics(
                    liveRegion: true,
                    child: Text(
                      ar
                          ? 'تم تغيير كلمة المرور. شارك الكلمة التي اخترتها مع المريض بطريقة آمنة. سيحتاج إلى تسجيل الدخول مجددًا عند الاتصال بالخادم.'
                          : 'Password changed. Share your chosen password securely with the patient. They must sign in again when connecting to the server.',
                    ),
                  )
                : Form(
                    key: _form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          ar
                              ? 'تأكيد إعادة التعيين للمريض: ${widget.patientName}. سيبطل الخادم رموز دخوله السابقة؛ لا يمسح هذا بيانات جهاز مفقود أو يوقفه أثناء انقطاع الاتصال.'
                              : 'Confirm a password reset for ${widget.patientName}. The server will reject previous login tokens; this does not erase a lost device or stop its offline use.',
                        ),
                        Gap.vMd,
                        if (_error != null) ...[
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                          Gap.vSm,
                        ],
                        TextFormField(
                          key: const ValueKey('reset-patient-password'),
                          controller: _password,
                          readOnly: _busy,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: ar
                                ? 'كلمة المرور الجديدة'
                                : 'New password',
                            helperText: ar
                                ? 'من 6 إلى 128 حرفًا'
                                : '6–128 characters',
                          ),
                          validator: (value) =>
                              value == null ||
                                  value.length < 6 ||
                                  value.length > 128
                              ? (ar
                                    ? 'أدخل من 6 إلى 128 حرفًا'
                                    : 'Enter 6–128 characters')
                              : null,
                        ),
                        Gap.vMd,
                        TextFormField(
                          key: const ValueKey('reset-patient-confirm'),
                          controller: _confirm,
                          readOnly: _busy,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: ar
                                ? 'تأكيد كلمة المرور'
                                : 'Confirm password',
                          ),
                          validator: (value) => value != _password.text
                              ? (ar
                                    ? 'كلمتا المرور غير متطابقتين'
                                    : 'Passwords do not match')
                              : null,
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(
              _saved || !valid
                  ? (ar ? 'تم' : 'Done')
                  : (ar ? 'إلغاء' : 'Cancel'),
            ),
          ),
          if (!_saved && valid)
            FilledButton(
              key: const ValueKey('confirm-patient-password-reset'),
              onPressed: _busy ? null : _save,
              child: Text(
                _busy
                    ? (ar ? 'جارٍ الحفظ…' : 'Saving…')
                    : (ar ? 'تأكيد إعادة التعيين' : 'Confirm reset'),
              ),
            ),
        ],
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
    this.prescriptions = const [],
    this.triggers = const [],
    this.serverListsLoaded = true,
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

  /// Null when no dose was due yet: «100 %» of nothing is not adherence.
  final double? adherence;
  final int activeMeds;

  /// False when prescriptions and triggers could not be fetched (offline).
  final bool serverListsLoaded;

  /// Prescriptions issued by the doctor for this patient (from backend API).
  final List<Map<String, dynamic>> prescriptions;

  /// Trigger diary entries recorded by the patient (from backend API).
  final List<Map<String, dynamic>> triggers;

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
    prescriptions: prescriptions,
    triggers: triggers,
    serverListsLoaded: serverListsLoaded,
  );

  int get alerts7d {
    final since = DateTime.now().subtract(const Duration(days: 7));
    return alerts.where((a) => a.timestamp.isAfter(since)).length;
  }

  /// The most recent assessment wins over `profile.currentStatus`: the profile
  /// is refreshed by a sync, the assessment by the device.
  bool get hasAssessment =>
      assessments.isNotEmpty &&
      assessments.first.confidence > 0 &&
      assessments.first.features['assessment_valid'] != false;

  RiskLabel? get latestLabel => hasAssessment ? assessments.first.label : null;

  DateTime? get observedAt =>
      hasAssessment ? assessments.first.timestamp : null;
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
  const _SummarySection({required this.data, this.onManageMeds});

  final _FileData data;
  final VoidCallback? onManageMeds;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final d = data;
    final view = RiskViewX.resolve(
      label: d.latestLabel,
      observedAt: d.observedAt,
      dataAvailable: d.hasAssessment,
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
            // The doctor's view: «my status» is the patient's own wording.
            eyebrow: Localizations.localeOf(context).languageCode == 'ar'
                ? 'الحالة الحالية'
                : 'Current status',
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
                  value: d.activeMeds == 0 || d.adherence == null
                      ? l.notSet
                      : _pct(d.adherence!),
                  // §3.4's own boundary: below 80 % the doctor should be looking
                  // at the medication list, not at the model.
                  view: d.activeMeds == 0 || d.adherence == null
                      ? RiskView.unknown
                      : (d.adherence! >= 0.8
                            ? RiskView.safe
                            : RiskView.caution),
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
          if (onManageMeds != null) ...[
            Gap.vMd,
            FilledButton.tonalIcon(
              onPressed: onManageMeds,
              icon: const Icon(Icons.medication_liquid_outlined),
              label: Text(
                Localizations.localeOf(context).languageCode == 'ar'
                    ? 'إدارة أدوية المريض ووصفها'
                    : 'Manage and prescribe medications',
              ),
            ),
          ],
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
          subtitle: a.displayMessage,
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
          : Column(children: [for (final e in events) _EventTile(event: e)]),
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
                    TimeAgo.stamp(event.at, AppLocalizations.of(context)),
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
      subtitle: r == null
          ? null
          : TimeAgo.stamp(r.timestamp, AppLocalizations.of(context)),
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
                        TimeAgo.stamp(
                          n.writtenAt,
                          AppLocalizations.of(context),
                        ),
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
  const _OperatingPointSection();

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return SectionCard(
      key: const ValueKey('model-operating-point-notice'),
      title: ar ? 'إعدادات النموذج' : 'Model configuration',
      icon: Icons.science_outlined,
      child: InfoNote(
        text: ar
            ? 'تعديل عتبة النموذج لكل مريض غير متاح في الإصدار الحالي. لا توجد نتائج موثقة تربط إعدادات الحساسية بنسبة كشف النوبات أو عدد الإنذارات الكاذبة لهذا المريض.'
            : 'Per-patient model thresholds cannot be changed in this version. No validated results link sensitivity settings to seizure detection or false-alarm rates for this patient.',
        icon: Icons.info_outline,
      ),
    );
  }
}

class _ReportsSection extends StatelessWidget {
  const _ReportsSection({
    required this.patientArgs,
    required this.enabled,
    required this.onPdf,
    required this.onCsv,
  });

  final bool enabled;
  final PatientRouteArgs patientArgs;
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
                  ? () => Navigator.pushNamed(
                      context,
                      Routes.reports,
                      arguments: patientArgs,
                    )
                  : null,
              icon: const Icon(Icons.table_chart_outlined),
              label: Text(
                Localizations.localeOf(context).languageCode == 'ar'
                    ? 'مركز التقارير وتصدير Excel'
                    : 'Reports center and Excel export',
              ),
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

// ──────────────────────────────────────── Doctor Prescription Section

class _PrescriptionSection extends StatefulWidget {
  const _PrescriptionSection({
    required this.patientId,
    required this.prescriptions,
    required this.onRefresh,
    this.loaded = true,
  });

  final String patientId;
  final List<Map<String, dynamic>> prescriptions;
  final bool loaded;
  final VoidCallback onRefresh;

  @override
  State<_PrescriptionSection> createState() => _PrescriptionSectionState();
}

class _PrescriptionSectionState extends State<_PrescriptionSection> {
  bool _busy = false;

  Future<void> _addPrescription({Map<String, dynamic>? existing}) async {
    if (_busy) return;
    final ar = AppLocalizations.of(context).isArabic;
    final app = context.read<AppState>();
    final formKey = GlobalKey<FormState>();
    final nameCtrl = TextEditingController(
      text: existing?['name'] as String? ?? '',
    );
    final doseCtrl = TextEditingController(
      text: existing?['dose'] as String? ?? '',
    );
    final schedCtrl = TextEditingController(
      text: existing?['schedule'] as String? ?? '',
    );
    final notesCtrl = TextEditingController(
      text: existing?['notes'] as String? ?? '',
    );

    var period = existing?['period_context'] as String? ?? 'morning';
    var mealContext = existing?['meal_context'] as String? ?? 'independent';
    var meal = existing?['meal_type'] as String? ?? 'breakfast';
    final times = List<String>.from(existing?['times'] as List? ?? const []);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateDialog) => AlertDialog(
          title: Text(
            existing == null
                ? (ar ? 'وصف دواء' : 'Prescribe medication')
                : (ar ? 'تعديل الوصفة' : 'Edit prescription'),
          ),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'اسم الدواء *',
                      hintText: 'مثال: Carbamazepine',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        v?.trim().isEmpty == true ? 'مطلوب' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: doseCtrl,
                    decoration: const InputDecoration(
                      labelText: 'الجرعة *',
                      hintText: 'مثال: 200mg',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        v?.trim().isEmpty == true ? 'مطلوب' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: schedCtrl,
                    decoration: const InputDecoration(
                      labelText: 'توقيت الأخذ *',
                      hintText: 'مثال: مرتين يومياً بعد الأكل',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        v?.trim().isEmpty == true ? 'مطلوب' : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: period,
                    decoration: const InputDecoration(labelText: 'الفترة'),
                    items: const [
                      DropdownMenuItem(value: 'morning', child: Text('صباحاً')),
                      DropdownMenuItem(value: 'noon', child: Text('ظهراً')),
                      DropdownMenuItem(value: 'evening', child: Text('مساءً')),
                      DropdownMenuItem(
                        value: 'bedtime',
                        child: Text('قبل النوم'),
                      ),
                    ],
                    onChanged: (v) => updateDialog(() => period = v!),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: mealContext,
                    decoration: const InputDecoration(
                      labelText: 'العلاقة بالوجبة',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'independent',
                        child: Text('غير مرتبط بوجبة'),
                      ),
                      DropdownMenuItem(
                        value: 'before_meal',
                        child: Text('قبل الوجبة'),
                      ),
                      DropdownMenuItem(
                        value: 'with_meal',
                        child: Text('مع الوجبة'),
                      ),
                      DropdownMenuItem(
                        value: 'after_meal',
                        child: Text('بعد الوجبة'),
                      ),
                    ],
                    onChanged: (v) => updateDialog(() => mealContext = v!),
                  ),
                  if (mealContext != 'independent')
                    DropdownButtonFormField<String>(
                      initialValue: meal,
                      decoration: const InputDecoration(labelText: 'الوجبة'),
                      items: const [
                        DropdownMenuItem(
                          value: 'breakfast',
                          child: Text('الإفطار'),
                        ),
                        DropdownMenuItem(value: 'lunch', child: Text('الغداء')),
                        DropdownMenuItem(
                          value: 'dinner',
                          child: Text('العشاء'),
                        ),
                      ],
                      onChanged: (v) => updateDialog(() => meal = v!),
                    ),
                  FormField<List<String>>(
                    key: ValueKey(times.join(',')),
                    initialValue: times,
                    validator: (_) =>
                        times.isEmpty ? 'حدد وقت جرعة واحداً على الأقل' : null,
                    builder: (field) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final time in times)
                              InputChip(
                                label: Text(
                                  TimeAgo.formatHhmm12h(time, isArabic: ar),
                                ),
                                onDeleted: () =>
                                    updateDialog(() => times.remove(time)),
                              ),
                          ],
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.add_alarm),
                          label: const Text('إضافة وقت جرعة'),
                          onPressed: () async {
                            final selected = await showTimePicker(
                              context: ctx,
                              initialTime: const TimeOfDay(hour: 8, minute: 0),
                              builder: (context, child) => MediaQuery(
                                data: MediaQuery.of(
                                  context,
                                ).copyWith(alwaysUse24HourFormat: false),
                                child: child!,
                              ),
                            );
                            if (selected == null || !ctx.mounted) return;
                            final time =
                                '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
                            updateDialog(() {
                              if (!times.contains(time)) times.add(time);
                              times.sort();
                            });
                          },
                        ),
                        if (field.errorText != null)
                          Text(
                            field.errorText!,
                            style: TextStyle(
                              color: Theme.of(ctx).colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextFormField(
                    controller: notesCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'ملاحظات',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
              },
              child: const Text('حفظ الوصفة'),
            ),
          ],
        ),
      ),
    );

    if (result != true || !mounted) return;
    setState(() => _busy = true);
    try {
      if (existing == null) {
        await app.api.prescribeMedication(
          patientId: widget.patientId,
          name: nameCtrl.text.trim(),
          dose: doseCtrl.text.trim(),
          schedule: schedCtrl.text.trim(),
          notes: notesCtrl.text.trim(),
          times: times,
          periodContext: period,
          mealContext: mealContext,
          mealType: mealContext == 'independent' ? null : meal,
        );
      } else {
        await app.api.sendJson(
          method: 'PATCH',
          path:
              '/doctor/patients/${widget.patientId}/prescriptions/${existing['id']}',
          body: {
            'name': nameCtrl.text.trim(),
            'dose': doseCtrl.text.trim(),
            'schedule': schedCtrl.text.trim(),
            'notes': notesCtrl.text.trim(),
            'times': times,
            'period_context': period,
            'meal_context': mealContext,
            'meal_type': mealContext == 'independent' ? null : meal,
          },
        );
      }
      if (mounted) AppSnack.success(context, 'تم حفظ الوصفة الطبية بنجاح ✓');
      widget.onRefresh();
    } catch (e) {
      if (mounted) AppSnack.error(context, 'تعذّر حفظ الوصفة');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelPrescription(Map<String, dynamic> rx) async {
    if (_busy) return;
    final ar = AppLocalizations.of(context).isArabic;
    final app = context.read<AppState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(ar ? 'إلغاء الوصفة؟' : 'Cancel prescription?'),
        content: Text(
          ar
              ? 'ستُعلّم وصفة ${rx['name']} كملغاة. راجع خطة المريض وأبلغه بالتغيير.'
              : 'Mark ${rx['name']} as cancelled. Review the patient plan and communicate the change.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(ar ? 'البقاء' : 'Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(ar ? 'إلغاء الوصفة' : 'Cancel prescription'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await app.api.sendJson(
        method: 'DELETE',
        path: '/doctor/patients/${widget.patientId}/prescriptions/${rx['id']}',
      );
      if (mounted) {
        AppSnack.success(
          context,
          ar ? 'أُلغيت الوصفة' : 'Prescription cancelled',
        );
        widget.onRefresh();
      }
    } catch (_) {
      if (mounted) {
        AppSnack.error(
          context,
          ar ? 'تعذر إلغاء الوصفة' : 'Unable to cancel prescription',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = widget.prescriptions
        .where((p) => p['active'] == true)
        .toList();
    final inactive = widget.prescriptions
        .where((p) => p['active'] != true)
        .toList();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: Insets.card,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: Radii.rMd,
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.medication_rounded,
                color: theme.colorScheme.primary,
                size: 20,
              ),
              Gap.hSm,
              Expanded(
                child: Text(
                  Localizations.localeOf(context).languageCode == 'ar'
                      ? 'الأدوية الموصوفة (${active.length} نشط)'
                      : 'Prescribed medications (${active.length} active)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (!_busy)
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(
                    Localizations.localeOf(context).languageCode == 'ar'
                        ? 'وصف دواء'
                        : 'Prescribe',
                  ),
                  onPressed: () => _addPrescription(),
                )
              else
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (widget.prescriptions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                !widget.loaded
                    ? (Localizations.localeOf(context).languageCode == 'ar'
                          ? 'تعذّر تحميل الوصفات دون اتصال.'
                          : 'Prescriptions could not be loaded offline.')
                    : Localizations.localeOf(context).languageCode == 'ar'
                    ? 'لا توجد أدوية موصوفة حتى الآن'
                    : 'No prescribed medications yet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else ...[
            // Active prescriptions
            ...active.map(
              (rx) => _RxTile(
                rx: rx,
                active: true,
                onEdit: _busy ? null : () => _addPrescription(existing: rx),
                onCancel: _busy ? null : () => _cancelPrescription(rx),
              ),
            ),
            // Inactive/cancelled
            if (inactive.isNotEmpty) ...[
              const Divider(height: 16),
              Text(
                'ملغاة / قديمة',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              ...inactive.take(3).map((rx) => _RxTile(rx: rx, active: false)),
            ],
          ],
        ],
      ),
    );
  }
}

class _RxTile extends StatelessWidget {
  const _RxTile({
    required this.rx,
    required this.active,
    this.onEdit,
    this.onCancel,
  });
  final VoidCallback? onEdit;
  final VoidCallback? onCancel;
  final Map<String, dynamic> rx;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            active ? Icons.check_circle_rounded : Icons.cancel_rounded,
            size: 16,
            color: active
                ? AppColors.accent(context, AccentTone.green).foreground
                : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          Gap.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${rx['name'] ?? ''} — ${rx['dose'] ?? ''}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: active ? null : theme.colorScheme.onSurfaceVariant,
                    decoration: active ? null : TextDecoration.lineThrough,
                  ),
                ),
                Text(
                  rx['schedule'] ?? '',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (active)
            PopupMenuButton<String>(
              enabled: onEdit != null || onCancel != null,
              tooltip: AppLocalizations.of(context).isArabic
                  ? 'إجراءات الوصفة'
                  : 'Prescription actions',
              onSelected: (value) {
                if (value == 'edit') {
                  onEdit?.call();
                } else {
                  onCancel?.call();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'edit',
                  child: Text(
                    AppLocalizations.of(context).isArabic ? 'تعديل' : 'Edit',
                  ),
                ),
                PopupMenuItem(
                  value: 'cancel',
                  child: Text(
                    AppLocalizations.of(context).isArabic
                        ? 'إلغاء الوصفة'
                        : 'Cancel prescription',
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────── Patient Triggers Section

class _TriggersSection extends StatelessWidget {
  const _TriggersSection({required this.triggers, this.loaded = true});
  final List<Map<String, dynamic>> triggers;
  final bool loaded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Group by type
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in triggers) {
      final type = (t['type'] as String?) ?? 'أخرى';
      (grouped[type] ??= []).add(t);
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: Insets.card,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: Radii.rMd,
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: AppColors.accent(context, AccentTone.orange).foreground,
                size: 20,
              ),
              Gap.hSm,
              Expanded(
                child: Text(
                  AppLocalizations.of(context).isArabic
                      ? 'مذكرات المحفزات (${triggers.length})'
                      : 'Trigger diary (${triggers.length})',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (triggers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                !loaded
                    ? (Localizations.localeOf(context).languageCode == 'ar'
                          ? 'تعذّر تحميل سجل المحفزات دون اتصال.'
                          : 'The trigger diary could not be loaded offline.')
                    : Localizations.localeOf(context).languageCode == 'ar'
                    ? 'لم يسجّل المريض أي محفزات حتى الآن'
                    : 'The patient has not logged any triggers yet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ...grouped.entries
                .take(5)
                .map(
                  (entry) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsetsDirectional.only(end: 8),
                          decoration: BoxDecoration(
                            color: AppColors.accent(
                              context,
                              AccentTone.orange,
                            ).foreground,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '${entry.key} (${entry.value.length})',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}
