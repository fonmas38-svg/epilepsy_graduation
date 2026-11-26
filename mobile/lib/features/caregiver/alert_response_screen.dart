import 'dart:async';
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
import '../../core/utils/external_actions.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/care_models.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../services/care_service.dart';
import '../shared/alerts_list.dart';
import '../shared/first_aid_view.dart';

/// Localised name of a seizure type. Public so the doctor's file and
/// adjudication screens render the same words for the same enum.
String seizureTypeLabel(SeizureType t, AppLocalizations l) => switch (t) {
  SeizureType.focal => l.seizureTypeFocal,
  SeizureType.generalized => l.seizureTypeGeneralized,
  SeizureType.absence => l.seizureTypeAbsence,
  SeizureType.other => l.seizureTypeOther,
};

/// Where a responder is, in words.
String responseStatusLabel(ResponseStatus s, AppLocalizations l) => switch (s) {
  ResponseStatus.seen => l.seenBy,
  ResponseStatus.acknowledged => l.respondedBy,
  ResponseStatus.onWay => l.onWay,
  ResponseStatus.arrived => l.arrived,
};

/// A duration in the largest unit that stays exact — «٩٠ ثانية» reads worse than
/// «دقيقة و٣٠ ثانية», and «١ دقيقة» is wrong for 90 s.
String seizureDurationLabel(int? seconds, AppLocalizations l) {
  if (seconds == null || seconds <= 0) return l.notSet;
  if (seconds < 60) return '$seconds ${l.secondsUnit}';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  if (s == 0) return '$m ${l.minutesUnit}';
  return '$m ${l.minutesUnit} $s ${l.secondsUnit}';
}

/// §4.2 — the screen a family member lands on when an alert arrives.
///
/// The plan asks for six things and this screen answers them in the order a
/// responder actually needs them:
///
/// 1. **What is happening** — the alert, its age, and (when consent allows) the
///    patient's current status.
/// 2. **Where** — coordinates handed off to the installed maps app.
/// 3. **How to help now** — call, message, «أنا في الطريق», «وصلت».
/// 4. **Who else is coming** — every recorded response, so two relatives do not
///    both assume the other is going.
/// 5. **What to do on arrival** — the illustrated first-aid steps.
/// 6. **What happened** — duration and type, documented afterwards.
///
/// Two deliberate limits, stated here rather than hidden:
///
/// * **There is no embedded map.** An in-app map needs a Maps SDK and a billed
///   API key, neither of which this project has. §4.2's «خريطة» is served by
///   handing the coordinates to whichever maps app the phone already has, which
///   also gives turn-by-turn navigation for free.
/// * **The app stores no phone number for the patient themselves** — `AppUser`
///   has one but a caregiver's device only ever sees a `PatientProfile`, which
///   does not. So «اتصال» dials the people on the patient's emergency list
///   (§3.5) and the treating doctor, which is who a responder coordinates with
///   anyway. Recorded as a data-model gap in `docs/frontend-implementation-ar.md`.
///
/// Access follows §4.3 strictly: the tier defaults to the least permissive one,
/// so live status and the patient's contact list stay hidden until the patient
/// has granted `basic` or above. Everything that is *about this alert* — the
/// alert itself, first aid, the responder list, documenting the event — is inside
/// even the `alertsOnly` tier, which is why the screen is still useful at the
/// default. The client gate is a courtesy; the real boundary is the backend, and
/// `GET /patients/{id}/consents` (§10) must exist for this to reflect the
/// patient's actual choice rather than the safe default.
class AlertResponseScreen extends StatefulWidget {
  const AlertResponseScreen({super.key, this.args});

  final PatientRouteArgs? args;

  @override
  State<AlertResponseScreen> createState() => _AlertResponseScreenState();
}

class _AlertResponseScreenState extends State<AlertResponseScreen> {
  late final AppState _app;
  late final AppUser? _owner;
  late final String _origin;
  late final int _revision;
  Timer? _responseTimer;
  bool _refreshingResponses = false;
  bool get _current =>
      mounted &&
      AppUser.sameSessionOwner(_owner, _app.auth.currentUser) &&
      _owner?.role == UserRole.caregiver &&
      _origin == _app.api.baseUrl &&
      _revision == _app.api.tokens.revision;
  bool _loading = true;
  bool _busy = false;
  String? _patientId;
  AlertItem? _alert;
  List<AlertResponse> _responses = const [];
  Failure? _failure;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _owner = _app.auth.currentUser;
    _origin = _app.api.baseUrl;
    _revision = _app.api.tokens.revision;
    _responseTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_current && _app.apiOnline && _alert != null) {
        unawaited(_refreshResponses(_alert!));
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _responseTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshResponses(AlertItem alert) async {
    if (!_current ||
        _refreshingResponses ||
        !_app.auth.canAccessPatient(alert.patientId)) {
      return;
    }
    _refreshingResponses = true;
    try {
      final rows = await _app.care.responsesFor(
        alert.id,
        patientId: alert.patientId,
        refreshRemote: true,
      );
      if (_current && _alert?.id == alert.id) setState(() => _responses = rows);
    } finally {
      _refreshingResponses = false;
    }
  }

  Future<void> _load() async {
    if (!_current) return;
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _failure = null;
    });
    final pid = widget.args?.patientId ?? app.activePatientId;
    _patientId = pid;
    if (pid == null || !app.auth.canAccessPatient(pid)) {
      setState(() => _loading = false);
      return;
    }
    try {
      // The screen can open straight from a push notification, before the
      // caregiver has tapped this patient in their list. Pointing `CareService`
      // at them here is what makes contacts, consents and documentation work at
      // all — without it every read below would be about the wrong patient.
      if (app.care.patientId != pid) {
        await app.care.loadFor(pid);
      }
      final alert = await _resolve(app, pid);
      final responses = alert == null
          ? const <AlertResponse>[]
          : await app.care.responsesFor(alert.id);
      if (!_current) return;
      setState(() {
        _alert = alert;
        _responses = responses;
        _loading = false;
      });
      await _markSeen(app, alert);
      if (_current && app.apiOnline && alert != null) {
        unawaited(_refreshResponses(alert));
      }
    } catch (e) {
      if (!_current) return;
      setState(() {
        _failure = Failure.from(e);
        _loading = false;
      });
    }
  }

  /// Live alerts win over stored ones for the same reason as on the patient's
  /// alert screen: an alert raised seconds ago may not be in the database yet.
  Future<AlertItem?> _resolve(AppState app, String pid) async {
    final wanted = widget.args?.alertId;
    final live = <AlertItem>[
      if (app.preAlert != null) app.preAlert!,
      if (app.lastAlert != null) app.lastAlert!,
    ];
    if (wanted != null) {
      for (final a in live) {
        if (a.id == wanted && a.patientId == pid) return a;
      }
    }
    final rows = await app.db.alertsFor(
      pid,
      limit: 100,
      serverOrigin: app.dataOrigin,
    );
    if (wanted != null) {
      for (final a in rows) {
        if (a.id == wanted && a.patientId == pid) return a;
      }
      // Asked for a specific alert and it is nowhere: say so instead of quietly
      // showing a different one, which would send help about the wrong event.
      return null;
    }
    if (live.isNotEmpty && live.first.patientId == pid) return live.first;
    return rows.isEmpty ? null : rows.first;
  }

  /// Opening the screen *is* seeing the alert, so it is recorded without asking.
  ///
  /// Written once per responder: a retry or a rebuild must not add a second
  /// «رأى التنبيه» row, or the patient's list of who is coming becomes noise.
  Future<void> _markSeen(AppState app, AlertItem? alert) async {
    if (alert == null || !_current) return;
    final me = app.auth.currentUser;
    if (me == null || me.role != UserRole.caregiver) return;
    if (_responses.any((r) => r.responderId == me.uid)) return;
    try {
      await app.care.respondToAlert(
        patientId: alert.patientId,
        alertId: alert.id,
        status: ResponseStatus.seen,
        responderId: me.uid,
        responderName: me.name,
      );
      if (!_current) return;
      await app.care.recordAccess('alert_response', actorName: me.name);
      final rows = await app.care.responsesFor(alert.id);
      if (_current) setState(() => _responses = rows);
    } catch (_) {
      // Seen-tracking is a courtesy, not a duty. It must never be the reason a
      // responder is looking at an error page instead of first-aid steps.
    }
  }

  Future<void> _respond(AlertItem alert, ResponseStatus status) async {
    if (!_current || _busy || !_app.auth.canAccessPatient(alert.patientId)) {
      return;
    }
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final me = app.auth.currentUser;
    setState(() => _busy = true);
    try {
      await app.care.respondToAlert(
        patientId: alert.patientId,
        alertId: alert.id,
        status: status,
        responderId: me?.uid ?? '',
        responderName: me?.name ?? '',
      );
      final rows = await app.care.responsesFor(alert.id);
      if (!_current || !mounted) return;
      setState(() => _responses = rows);
      AppSnack.success(context, l.savedLocallyWillSync);
    } catch (_) {
      if (_current && mounted) AppSnack.error(context, l.errUnknown);
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _dial(String phone) async {
    final l = AppLocalizations.of(context);
    if (await ExternalActions.dial(phone)) return;
    // No dialer, or the launch was refused. The number is more useful in the
    // clipboard than in an error message.
    await ExternalActions.copy(phone);
    if (mounted) AppSnack.warn(context, '${l.copied} — $phone');
  }

  Future<void> _sms(String phone, String body) async {
    final l = AppLocalizations.of(context);
    if (await ExternalActions.sms(phone, body: body)) return;
    await ExternalActions.copy(phone);
    if (mounted) AppSnack.warn(context, '${l.copied} — $phone');
  }

  Future<void> _navigate(_Coords c, {required bool route}) async {
    final l = AppLocalizations.of(context);
    final ok = route
        ? await ExternalActions.directions(
            latitude: c.latitude,
            longitude: c.longitude,
          )
        : await ExternalActions.showOnMap(
            latitude: c.latitude,
            longitude: c.longitude,
          );
    if (ok || !mounted) return;
    await ExternalActions.copy(c.text);
    if (mounted) AppSnack.warn(context, '${l.copied} — ${c.text}');
  }

  Future<void> _document(AlertItem alert) async {
    if (!_current || _busy || !_app.auth.canAccessPatient(alert.patientId)) {
      return;
    }
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final result = await showModalBottomSheet<_SeizureDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _DocumentSheet(),
    );
    if (result == null || !_current) return;
    try {
      await app.care.logSeizure(
        occurredAt: alert.timestamp,
        durationSeconds: result.durationSeconds,
        type: result.type,
        notes: result.notes,
        reportedBy: _owner?.uid ?? '',
        alertId: alert.id,
      );
      if (_current && mounted) {
        AppSnack.success(context, l.savedLocallyWillSync);
      }
    } catch (_) {
      if (_current && mounted) AppSnack.error(context, l.errUnknown);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    if (!_current) return const Scaffold(body: SizedBox.shrink());
    final pid = _patientId;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.respondTitle),
        actions: [
          IconButton(
            tooltip: l.retry,
            onPressed: _busy || _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: pid == null
          ? EmptyState(
              title: l.noPatientSelected,
              body: l.noLinkedPatientsBody,
              icon: Icons.person_search_outlined,
            )
          : AsyncView<AlertItem>(
              loading: _loading,
              failure: _failure,
              value: _alert,
              onRetry: _load,
              emptyTitle: l.alertNotFound,
              emptyBody: l.emptyBody,
              emptyIcon: Icons.notifications_off_outlined,
              builder: (context, alert) => RefreshIndicator(
                onRefresh: _load,
                child: _Body(
                  app: app,
                  alert: alert,
                  patientId: pid,
                  responses: _responses,
                  busy: _busy,
                  onRespond: (status) => _respond(alert, status),
                  onDial: _dial,
                  onSms: _sms,
                  onNavigate: _navigate,
                  onDocument: () => _document(alert),
                ),
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Coordinates
// ---------------------------------------------------------------------------

/// A location parsed back out of an alert message.
///
/// `SyncService.sendSos` writes the patient's position into the alert text as a
/// `https://maps.google.com/?q=lat,lon` link — `AlertItem` has no latitude or
/// longitude field. Rather than pretend one exists, this reads the link back.
/// It is recorded in `docs/frontend-implementation-ar.md` as the reason
/// `AlertItem` should gain real coordinate fields.
class _Coords {
  const _Coords(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  String get text =>
      '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';

  static final _pattern = RegExp(r'q=(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)');

  static _Coords? parse(String message) {
    final m = _pattern.firstMatch(message);
    if (m == null) return null;
    final lat = double.tryParse(m.group(1) ?? '');
    final lon = double.tryParse(m.group(2) ?? '');
    if (lat == null || lon == null) return null;
    // Anything outside the valid range is a parse accident, not a position.
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return _Coords(lat, lon);
  }

  /// The message without the link, so the responder reads a sentence instead of
  /// a sentence plus forty characters of URL. Nothing is lost: the link becomes
  /// the two buttons in the location card.
  static String strip(String message) {
    var out = message.replaceAll(RegExp(r'https?://\S+'), '').trim();
    // `sendSos` writes «الموقع: <url>», so with the URL gone the label is left
    // dangling. Keyed on the trailing colon rather than on the word itself,
    // which keeps this working whatever language the message was built in.
    if (out.endsWith(':') || out.endsWith('：')) {
      final cut = out.lastIndexOf(RegExp(r'\s'));
      out = cut <= 0 ? '' : out.substring(0, cut).trim();
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

class _Body extends StatelessWidget {
  const _Body({
    required this.app,
    required this.alert,
    required this.patientId,
    required this.responses,
    required this.busy,
    required this.onRespond,
    required this.onDial,
    required this.onSms,
    required this.onNavigate,
    required this.onDocument,
  });

  final AppState app;
  final AlertItem alert;
  final String patientId;
  final List<AlertResponse> responses;
  final bool busy;
  final void Function(ResponseStatus status) onRespond;
  final void Function(String phone) onDial;
  final void Function(String phone, String body) onSms;
  final void Function(_Coords c, {required bool route}) onNavigate;
  final VoidCallback onDocument;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final care = app.care;
    final me = app.auth.currentUser;
    final myUid = me?.uid ?? '';
    final level = me == null ? ConsentLevel.alertsOnly : care.levelFor(me.uid);
    final profile = app.auth.patientById(patientId);
    final coords = _Coords.parse(alert.message);
    final myConsent = _consentFor(care, myUid);
    final mine = responses
        .where((r) => myUid.isNotEmpty && r.responderId == myUid)
        .toList();

    return ResponsiveContent(
      maxWidth: 850,
      child: ListView(
        padding: Insets.pageBottomSafe,
        children: [
          OfflineBanner(
            visible: !app.apiOnline,
            mode: app.operatingMode,
            onSyncNow: app.syncNow,
            lastUpdateLabel: care.lastSyncedAt == null
                ? null
                : TimeAgo.since(care.lastSyncedAt, l),
            pendingCount: care.pendingCount,
          ),
          _Headline(alert: alert, patientName: profile?.name ?? ''),
          Gap.vMd,
          _StatusSection(app: app, level: level),
          Gap.vMd,
          _LocationSection(
            coords: coords,
            consent: myConsent,
            onNavigate: onNavigate,
          ),
          Gap.vMd,
          _ActionsSection(
            alert: alert,
            patientName: profile?.name ?? '',
            patientPhone: profile?.phone ?? '',
            contacts: level.allowsLiveStatus ? care.contacts : const [],
            doctorPhone: level.allowsLiveStatus
                ? (care.medicalCard?.doctorPhone ?? '')
                : '',
            coords: coords,
            busy: busy,
            myStatuses: mine.map((r) => r.status).toSet(),
            onRespond: onRespond,
            onDial: onDial,
            onSms: onSms,
          ),
          Gap.vMd,
          _RespondersSection(responses: responses),
          Gap.vMd,
          if (care.medicalCard != null && !care.medicalCard!.isEmpty) ...[
            _CaregiverMedicalCardSection(
              card: care.medicalCard!,
              onDial: onDial,
            ),
            Gap.vMd,
          ],
          // Steps before paperwork. Documentation matters, but not while the
          // seizure is still happening.
          const FirstAidView(),
          Gap.vMd,
          _DocumentSection(
            logs: _visibleLogs(care, level, myUid),
            busy: busy,
            onDocument: onDocument,
          ),
        ],
      ),
    );
  }

  static CaregiverConsent? _consentFor(CareService care, String uid) {
    if (uid.isEmpty) return null;
    for (final c in care.consents) {
      if (c.caregiverId == uid) return c;
    }
    return null;
  }

  /// §4.3 gates *history*, not a responder's own eyewitness note. Below the
  /// `full` tier a caregiver still sees the entries they wrote themselves — a
  /// report you cannot re-read is a report you cannot correct.
  static List<SeizureLog> _visibleLogs(
    CareService care,
    ConsentLevel level,
    String uid,
  ) {
    if (level.allowsHistory) return care.seizureLogs;
    if (uid.isEmpty) return const [];
    return care.seizureLogs.where((s) => s.reportedBy == uid).toList();
  }
}

// --- headline ---------------------------------------------------------------

class _Headline extends StatelessWidget {
  const _Headline({required this.alert, required this.patientName});

  final AlertItem alert;
  final String patientName;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final s = alertSeverity(alert.severity, l);
    final tone = AppColors.of(context, s.view);
    final age = DateTime.now().difference(alert.timestamp);
    final body = _Coords.strip(alert.message);

    return Container(
      margin: Insets.page,
      padding: Insets.card,
      decoration: BoxDecoration(
        color: tone.container,
        border: Border.all(color: tone.border),
        borderRadius: Radii.rLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RiskBadge(view: s.view, labelOverride: s.label),
              const Spacer(),
              Text(
                TimeAgo.clock(alert.timestamp, AppLocalizations.of(context)),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: tone.foreground,
                ),
              ),
            ],
          ),
          Gap.vSm,
          // The age of the alert, not just its timestamp: «قبل ٤ دقائق» answers
          // «هل أنا متأخر؟», «14:32» does not.
          Text(
            l.sinceAlert(TimeAgo.span(age, l)),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: tone.foreground,
            ),
          ),
          if (patientName.isNotEmpty) ...[
            Gap.vXs,
            LabeledValue(
              label: l.patientLabel,
              value: patientName,
              icon: Icons.person_outline,
            ),
          ],
          if (body.isNotEmpty) ...[
            Gap.vXs,
            Text(body, style: theme.textTheme.bodyMedium),
          ],
          Gap.vXs,
          LabeledValue(
            label: l.alertTime,
            value: TimeAgo.stamp(alert.timestamp, AppLocalizations.of(context)),
            icon: Icons.schedule_outlined,
          ),
        ],
      ),
    );
  }
}

// --- status -----------------------------------------------------------------

class _StatusSection extends StatelessWidget {
  const _StatusSection({required this.app, required this.level});

  final AppState app;
  final ConsentLevel level;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return SectionCard(
      title: l.lastKnownStatus,
      icon: Icons.monitor_heart_outlined,
      // Not a soft warning: below `basic` there is nothing to show, and saying
      // so plainly is better than an empty card the responder keeps checking.
      child: !level.allowsLiveStatus
          ? InfoNote(
              text: l.consentAlertsOnlyDesc,
              icon: Icons.lock_outline,
              view: RiskView.unknown,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RiskGauge(
                  view: app.riskView,
                  leadTimeMin: app.monitoring.latestPrediction?.leadTimeMin,
                  freshnessLabel: TimeAgo.since(app.lastObservedAt, l),
                ),
                Gap.vSm,
                RiskStrip(view: app.riskView),
              ],
            ),
    );
  }
}

// --- location ---------------------------------------------------------------

class _LocationSection extends StatelessWidget {
  const _LocationSection({
    required this.coords,
    required this.consent,
    required this.onNavigate,
  });

  final _Coords? coords;
  final CaregiverConsent? consent;
  final void Function(_Coords c, {required bool route}) onNavigate;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = coords;

    return SectionCard(
      title: l.currentLocation,
      icon: Icons.person_pin_circle_outlined,
      child: c == null
          // Two different facts, two different sentences. «مغلق بقرار المريض» is
          // final and needs no retry; «غير متوفر» might resolve on the next
          // alert. Collapsing them would make a choice look like a failure.
          ? InfoNote(
              text: consent != null && !consent!.shareLocation
                  ? l.locationDisabledByPatient
                  : l.locationUnavailable,
              icon: Icons.location_off_outlined,
              view: RiskView.unknown,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledValue(
                  label: l.currentLocation,
                  value: c.text,
                  icon: Icons.place_outlined,
                ),
                Gap.vSm,
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: A11y.minTouchTarget,
                        child: FilledButton.icon(
                          onPressed: () => onNavigate(c, route: true),
                          icon: const Icon(Icons.directions_outlined),
                          label: Text(l.directions),
                        ),
                      ),
                    ),
                    Gap.hSm,
                    Expanded(
                      child: SizedBox(
                        height: A11y.minTouchTarget,
                        child: OutlinedButton.icon(
                          onPressed: () => onNavigate(c, route: false),
                          icon: const Icon(Icons.map_outlined),
                          label: Text(l.currentLocation),
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

// --- actions ----------------------------------------------------------------

class _ActionsSection extends StatelessWidget {
  const _ActionsSection({
    required this.alert,
    required this.patientName,
    this.patientPhone = '',
    required this.contacts,
    required this.doctorPhone,
    required this.coords,
    required this.busy,
    required this.myStatuses,
    required this.onRespond,
    required this.onDial,
    required this.onSms,
  });

  final AlertItem alert;
  final String patientName;
  final String patientPhone;
  final List<EmergencyContact> contacts;
  final String doctorPhone;
  final _Coords? coords;
  final bool busy;
  final Set<ResponseStatus> myStatuses;
  final void Function(ResponseStatus status) onRespond;
  final void Function(String phone) onDial;
  final void Function(String phone, String body) onSms;

  /// What a coordinating message should already contain, so the responder does
  /// not have to type an address with one hand.
  String _smsBody(AppLocalizations l) {
    final who = patientName.isEmpty ? l.patientLabel : patientName;
    final where = coords == null ? '' : ' — ${coords!.text}';
    return '${l.onMyWay}: $who$where';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final onWay = myStatuses.contains(ResponseStatus.onWay);
    final arrived = myStatuses.contains(ResponseStatus.arrived);

    return SectionCard(
      title: l.quickActions,
      icon: Icons.touch_app_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // «أنا في الطريق» is the one action that changes what the patient's
          // phone shows, so it leads and stays the largest.
          SizedBox(
            height: A11y.emergencyTouchTarget,
            child: FilledButton.icon(
              onPressed: busy || onWay || arrived
                  ? null
                  : () => onRespond(ResponseStatus.onWay),
              icon: const Icon(Icons.directions_walk_outlined),
              label: Text(onWay || arrived ? l.onMyWayRecorded : l.onMyWay),
            ),
          ),
          Gap.vSm,
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: busy || arrived
                  ? null
                  : () => onRespond(ResponseStatus.arrived),
              icon: const Icon(Icons.check_circle_outline),
              label: Text(l.arrived),
            ),
          ),
          Gap.vMd,
          if (contacts.isEmpty && doctorPhone.isEmpty && patientPhone.isEmpty)
            EmptyState(
              title: l.noRespondersYet,
              body: l.contactsHint,
              icon: Icons.contact_phone_outlined,
              compact: true,
            )
          else ...[
            if (patientPhone.isNotEmpty)
              _ContactRow(
                name: 'هاتف المريض المباشر',
                subtitle: patientPhone,
                phone: patientPhone,
                icon: Icons.phone_android_outlined,
                onDial: onDial,
                onSms: (phone) => onSms(phone, _smsBody(l)),
              ),
            for (final c in contacts)
              _ContactRow(
                name: c.name.isEmpty ? c.phone : c.name,
                subtitle: c.relation.isEmpty ? c.phone : c.relation,
                phone: c.phone,
                icon: Icons.person_outline,
                onDial: onDial,
                onSms: (phone) => onSms(phone, _smsBody(l)),
              ),
            if (doctorPhone.isNotEmpty)
              _ContactRow(
                name: l.doctorPhone,
                subtitle: doctorPhone,
                phone: doctorPhone,
                icon: Icons.medical_services_outlined,
                onDial: onDial,
                onSms: (phone) => onSms(phone, _smsBody(l)),
              ),
          ],
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.name,
    required this.subtitle,
    required this.phone,
    required this.icon,
    required this.onDial,
    required this.onSms,
  });

  final String name;
  final String subtitle;
  final String phone;
  final IconData icon;
  final void Function(String phone) onDial;
  final void Function(String phone) onSms;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(name),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l.message,
            onPressed: () => onSms(phone),
            icon: const Icon(Icons.sms_outlined),
          ),
          IconButton(
            tooltip: l.call,
            onPressed: () => onDial(phone),
            icon: const Icon(Icons.call_outlined),
          ),
        ],
      ),
    );
  }
}

// --- responders -------------------------------------------------------------

class _RespondersSection extends StatelessWidget {
  const _RespondersSection({required this.responses});

  final List<AlertResponse> responses;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // Newest first: what someone did two minutes ago matters more than the
    // moment they opened the notification.
    final rows = [...responses]..sort((a, b) => b.at.compareTo(a.at));

    return SectionCard(
      title: l.respondersSection,
      icon: Icons.groups_outlined,
      child: rows.isEmpty
          ? EmptyState(
              title: l.noRespondersYet,
              body: l.respondersHint,
              icon: Icons.groups_outlined,
              compact: true,
            )
          : Column(
              children: [
                for (final r in rows)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(_icon(r.status), size: 20),
                    title: Text(
                      r.responderName.isEmpty
                          ? responseStatusLabel(r.status, l)
                          : '${r.responderName} — '
                                '${responseStatusLabel(r.status, l)}',
                    ),
                    subtitle: Text(
                      [
                        TimeAgo.since(r.at, l),
                        if (!r.synced) l.pendingSync,
                      ].join(' · '),
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
    );
  }

  static IconData _icon(ResponseStatus s) => switch (s) {
    ResponseStatus.seen => Icons.visibility_outlined,
    ResponseStatus.acknowledged => Icons.thumb_up_outlined,
    ResponseStatus.onWay => Icons.directions_walk_outlined,
    ResponseStatus.arrived => Icons.check_circle_outline,
  };
}

// --- documentation ----------------------------------------------------------

class _DocumentSection extends StatelessWidget {
  const _DocumentSection({
    required this.logs,
    required this.busy,
    required this.onDocument,
  });

  final List<SeizureLog> logs;
  final bool busy;
  final VoidCallback onDocument;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final recent = logs.take(3).toList();

    return SectionCard(
      title: l.documentSeizure,
      icon: Icons.note_alt_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onDocument,
              icon: const Icon(Icons.edit_note_outlined),
              label: Text(l.documentSeizure),
            ),
          ),
          if (recent.isNotEmpty) ...[
            Gap.vMd,
            Text(l.recentEvents, style: theme.textTheme.labelLarge),
            for (final s in recent)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.timer_outlined, size: 20),
                title: Text(
                  '${seizureTypeLabel(s.type, l)} — '
                  '${seizureDurationLabel(s.durationSeconds, l)}',
                ),
                subtitle: Text(
                  TimeAgo.stamp(s.occurredAt, AppLocalizations.of(context)),
                  style: theme.textTheme.labelSmall,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// What the sheet hands back. A plain value object so the sheet owns no service
/// calls — the screen writes it, which keeps the offline path in one place.
class _SeizureDraft {
  const _SeizureDraft({
    required this.durationSeconds,
    required this.type,
    required this.notes,
  });

  final int? durationSeconds;
  final SeizureType type;
  final String notes;
}

class _DocumentSheet extends StatefulWidget {
  const _DocumentSheet();

  @override
  State<_DocumentSheet> createState() => _DocumentSheetState();
}

class _DocumentSheetState extends State<_DocumentSheet> {
  /// Presets first, free entry second. Someone who has just watched a seizure is
  /// estimating, not reading a stopwatch, and four taps beats a keyboard.
  static const _presets = [30, 60, 120, 180, 300];

  final _seconds = TextEditingController();
  final _notes = TextEditingController();
  SeizureType _type = SeizureType.other;

  @override
  void dispose() {
    _seconds.dispose();
    _notes.dispose();
    super.dispose();
  }

  int? get _value {
    final v = int.tryParse(_seconds.text.trim());
    if (v == null || v <= 0) return null;
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final seconds = _value;

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: Gap.lg + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.documentSeizure, style: theme.textTheme.titleMedium),
            Gap.vMd,
            Text(l.seizureDuration, style: theme.textTheme.labelLarge),
            Gap.vXs,
            Wrap(
              spacing: Gap.xs,
              runSpacing: Gap.xs,
              children: [
                for (final p in _presets)
                  ChoiceChip(
                    selected: seconds == p,
                    onSelected: (_) => setState(() => _seconds.text = '$p'),
                    label: Text(seizureDurationLabel(p, l)),
                  ),
              ],
            ),
            Gap.vSm,
            TextField(
              controller: _seconds,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '${l.seizureDuration} (${l.secondsUnit})',
                prefixIcon: const Icon(Icons.timer_outlined),
              ),
            ),
            // The one clinical rule that must not wait for the first-aid list to
            // be scrolled: five minutes means an ambulance.
            if (seconds != null && seconds >= 300) ...[
              Gap.vSm,
              InfoNote(
                text: l.firstAidCallAmbulance,
                icon: Icons.local_hospital_outlined,
                view: RiskView.danger,
              ),
            ],
            Gap.vMd,
            Text(l.seizureType, style: theme.textTheme.labelLarge),
            Gap.vXs,
            Wrap(
              spacing: Gap.xs,
              runSpacing: Gap.xs,
              children: [
                for (final t in SeizureType.values)
                  ChoiceChip(
                    selected: _type == t,
                    onSelected: (_) => setState(() => _type = t),
                    label: Text(seizureTypeLabel(t, l)),
                  ),
              ],
            ),
            Gap.vMd,
            TextField(
              controller: _notes,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: l.seizureNotes,
                alignLabelWithHint: true,
              ),
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
                    // Saveable with no duration on purpose: «لا أعرف كم دامت»
                    // is a truthful answer, and refusing it would push the
                    // responder into inventing a number.
                    child: FilledButton(
                      onPressed: () => Navigator.pop(
                        context,
                        _SeizureDraft(
                          durationSeconds: _value,
                          type: _type,
                          notes: _notes.text,
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

class _CaregiverMedicalCardSection extends StatelessWidget {
  const _CaregiverMedicalCardSection({
    required this.card,
    required this.onDial,
  });

  final MedicalCard card;
  final void Function(String phone) onDial;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return SectionCard(
      title: l.medicalCard,
      icon: Icons.medical_information_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (card.bloodType.isNotEmpty)
            LabeledValue(
              label: l.bloodType,
              value: card.bloodType,
              icon: Icons.bloodtype_outlined,
            ),
          if (card.allergies.isNotEmpty)
            LabeledValue(
              label: l.allergies,
              value: card.allergies,
              valueColor: theme.colorScheme.error,
              icon: Icons.warning_amber_rounded,
            ),
          if (card.doctorName.isNotEmpty)
            LabeledValue(
              label: l.treatingDoctor,
              value: card.doctorName,
              icon: Icons.medical_services_outlined,
            ),
          if (card.notes.isNotEmpty) ...[
            Gap.vXs,
            InfoNote(
              text: 'تعليمات الإنقاذ والجرعات الإسعافية: ${card.notes}',
              icon: Icons.emergency_outlined,
              view: RiskView.caution,
            ),
          ],
          if (card.doctorPhone.isNotEmpty) ...[
            Gap.vSm,
            OutlinedButton.icon(
              onPressed: () => onDial(card.doctorPhone),
              icon: const Icon(Icons.phone),
              label: Text(
                AppLocalizations.of(context).isArabic
                    ? 'اتصال بالطبيب المعالج (${card.doctorPhone})'
                    : 'Call the treating doctor (${card.doctorPhone})',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
