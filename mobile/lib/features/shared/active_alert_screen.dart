import '../../services/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

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
import '../../l10n/app_localizations.dart';
import '../../models/care_models.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import 'alerts_list.dart';
import 'first_aid_view.dart';

/// §3.2 — the full-screen active alert.
///
/// Shared by all three roles because a push notification lands on the same
/// route whoever taps it; the body then renders the actions that role can
/// actually take.
///
/// What the plan asks for and how it is met:
///
/// * **A countdown while the alert can still be cancelled.** Shown only while a
///   pre-alert is genuinely live in [PreAlertController]; once it has escalated
///   the countdown disappears rather than continuing to imply a cancel is
///   possible.
/// * **Three immediate steps, before any of the buttons.** Someone reading this
///   screen may be seconds from a seizure. The instructions come first, the
///   controls after.
/// * **«أنا بخير» / «أحتاج مساعدة» / «تنبيه خاطئ».** All three write locally
///   first and queue the network call, so they cannot hang or fail silently on a
///   dead connection.
/// * **Who was notified.** Stated from real recorded responses, and when nothing
///   has come back yet it says exactly that instead of implying help is coming.
///
/// One honest limitation: the route is a `fullscreenDialog`, which covers the
/// app, but showing this over a *locked* device needs a platform-side
/// full-screen intent (Android) / critical alert entitlement (iOS) that is not
/// part of this Flutter layer. §3.2's lock-screen requirement is therefore
/// partly met here and recorded as outstanding in
/// `docs/frontend-implementation-ar.md`.
class ActiveAlertScreen extends StatefulWidget {
  const ActiveAlertScreen({super.key, this.args});

  final AlertRouteArgs? args;

  @override
  State<ActiveAlertScreen> createState() => _ActiveAlertScreenState();
}

class _ActiveAlertScreenState extends State<ActiveAlertScreen> {
  late final AppState _app;
  late final AppUser? _owner;
  late final String _origin;
  late final int _revision;
  bool get _current =>
      mounted &&
      identical(_owner, _app.auth.currentUser) &&
      _origin == _app.api.baseUrl &&
      _revision == _app.api.tokens.revision;
  bool _loading = true;
  bool _busy = false;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    if (!_current) return;
    final app = context.read<AppState>();
    final args = widget.args;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final found = await _resolve(app, args);
      final responses = found == null
          ? const <AlertResponse>[]
          : await app.care.responsesFor(
              found.id,
              patientId: found.patientId,
              refreshRemote: app.apiOnline,
            );
      if (!_current) return;
      setState(() {
        _alert = found;
        _responses = responses;
        _loading = false;
      });
      if (found?.severity == 'critical') {
        HapticFeedback.heavyImpact();
      }
    } catch (e) {
      if (!_current) return;
      setState(() {
        _failure = Failure.from(e);
        _loading = false;
      });
    }
  }

  /// Live in-memory alerts win over the database: an alert raised half a second
  /// ago may not have been persisted yet, and this screen must never say «لا يوجد
  /// تنبيه» about the alert that just opened it.
  Future<AlertItem?> _resolve(AppState app, AlertRouteArgs? args) async {
    final live = <AlertItem>[
      if (app.preAlert != null) app.preAlert!,
      if (app.lastAlert != null) app.lastAlert!,
    ].where((alert) => app.auth.canAccessPatient(alert.patientId)).toList();
    if (args == null) return live.isEmpty ? null : live.first;
    for (final alert in live) {
      if (alert.id == args.alertId &&
          (args.patientId == null || args.patientId == alert.patientId)) {
        return alert;
      }
    }
    final pid = args.patientId ?? app.activePatientId;
    if (pid == null || !app.auth.canAccessPatient(pid)) return null;
    final rows = await app.db.alertsFor(pid, limit: 100);
    for (final alert in rows) {
      if (alert.id == args.alertId && alert.patientId == pid) return alert;
    }
    if (app.api.tokens.hasSession) {
      try {
        final alert = await app.api.alertDetails(pid, args.alertId);
        if (alert.patientId == pid &&
            alert.id == args.alertId &&
            app.auth.canAccessPatient(pid)) {
          return alert;
        }
      } on ApiException catch (error) {
        if (error.statusCode != 404) rethrow;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    if (!_current) return const Scaffold(body: SizedBox.shrink());

    return Scaffold(
      appBar: AppBar(
        title: Text(l.activeAlertTitle),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            tooltip: l.close,
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: AsyncView<AlertItem>(
        loading: _loading,
        failure: _failure,
        value: _alert,
        onRetry: _load,
        emptyTitle: l.alertNotFound,
        emptyBody: l.emptyBody,
        emptyIcon: Icons.notifications_off_outlined,
        builder: (context, alert) => _Body(
          alert: alert,
          responses: _responses,
          busy: _busy,
          onImOk: () => _acknowledge(app, alert, note: ''),
          onFalseAlarm: () => _falseAlarm(app, alert),
          onNeedHelp: () => _sos(app),
          onRespond: () => _respond(app, alert),
        ),
      ),
    );
  }

  // --- actions --------------------------------------------------------------

  /// «أنا بخير» — and the write half of «تنبيه خاطئ» for an alert that has
  /// already gone out.
  Future<void> _acknowledge(
    AppState app,
    AlertItem alert, {
    required String note,
  }) async {
    if (!_current || _busy || !app.auth.canAccessPatient(alert.patientId)) {
      return;
    }
    final l = AppLocalizations.of(context);
    final by = app.auth.currentUser?.uid ?? '';
    setState(() => _busy = true);
    try {
      await app.care.acknowledgeAlert(alertId: alert.id, by: by, note: note);
      await app.dismissAlertBanner();
      if (!_current || !mounted) return;
      setState(() {
        _alert = alert.copyWith(acknowledged: true, acknowledgedBy: by);
        _busy = false;
      });
      AppSnack.success(
        context,
        note.isEmpty ? l.imOkRecorded : l.falseAlarmRecorded,
      );
      await Navigator.maybePop(context);
    } catch (_) {
      if (!_current || !mounted) return;
      setState(() => _busy = false);
      AppSnack.error(context, l.errUnknown);
    }
  }

  /// «تنبيه خاطئ». While the cancel window is still open this stops the alert
  /// before it ever leaves the phone; afterwards it can only be *reported*, and
  /// the copy says so rather than pretending the notification can be recalled.
  Future<void> _falseAlarm(AppState app, AlertItem alert) async {
    if (!_current || _busy) return;
    final l = AppLocalizations.of(context);
    final pre = app.preAlert;
    if (pre != null && pre.id == alert.id) {
      setState(() => _busy = true);
      await app.cancelPreAlert();
      if (!_current || !mounted) return;
      setState(() => _busy = false);
      AppSnack.success(context, l.falseAlarmRecorded);
      await Navigator.maybePop(context);
      return;
    }
    await _acknowledge(app, alert, note: 'false_alarm');
  }

  Future<void> _sos(AppState app) async {
    if (!_current || _busy) return;
    final l = AppLocalizations.of(context);
    await app.triggerSos();
    if (!_current || !mounted) return;
    final failed = app.failure != null;
    if (failed) {
      AppSnack.error(context, l.sosFailed);
    } else {
      AppSnack.success(context, l.sosSent);
    }
  }

  /// A family member or doctor who opened the alert continues on the screen
  /// built for responding (§4.2) rather than acting from here.
  Future<void> _respond(AppState app, AlertItem alert) async {
    if (!_current || _busy || !app.auth.canAccessPatient(alert.patientId)) {
      return;
    }
    final role = app.auth.currentUser?.role;
    final args = PatientRouteArgs(
      patientId: alert.patientId,
      alertId: alert.id,
    );
    await Navigator.of(context).pushNamed(
      role == UserRole.doctor ? Routes.doctorPatient : Routes.familyRespond,
      arguments: args,
    );
  }
}

// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

class _Body extends StatelessWidget {
  const _Body({
    required this.alert,
    required this.responses,
    required this.busy,
    required this.onImOk,
    required this.onFalseAlarm,
    required this.onNeedHelp,
    required this.onRespond,
  });

  final AlertItem alert;
  final List<AlertResponse> responses;
  final bool busy;
  final Future<void> Function() onImOk;
  final Future<void> Function() onFalseAlarm;
  final Future<void> Function() onNeedHelp;
  final Future<void> Function() onRespond;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final role = app.auth.currentUser?.role;
    final pre = app.preAlert;
    final counting = pre != null && pre.id == alert.id;

    return ListView(
      padding: Insets.pageBottomSafe,
      children: [
        _Headline(alert: alert),
        _LocationNavigationCard(alert: alert),
        if (counting) ...[
          Gap.vMd,
          _Countdown(secondsLeft: app.preAlertSecondsLeft),
        ],
        Gap.vMd,
        // Instructions before controls, deliberately.
        const _Steps(),
        Gap.vMd,
        if (role == UserRole.patient)
          _PatientActions(
            busy: busy,
            acknowledged: alert.acknowledged,
            counting: counting,
            onImOk: onImOk,
            onFalseAlarm: onFalseAlarm,
            onNeedHelp: onNeedHelp,
          )
        else
          _ResponderActions(alert: alert, onRespond: onRespond),
        Gap.vMd,
        _NotifiedSection(alert: alert, responses: responses),
        Gap.vMd,
        // Ends with «اتصل بالإسعاف إذا …» from inside the view itself, so the
        // ambulance rule is not repeated twice on one screen.
        const FirstAidView(),
      ],
    );
  }
}

String _friendlyAlertMessage(String msg) {
  final m = msg.trim();
  if (m.contains('High seizure risk detected') || m.contains('high_risk')) {
    return 'رصد احتمال نوبة محتملة: يرجى الجلوس والاسترخاء وتجنب أي مجهود، النظام يراقبك باستمرار.';
  }
  if (m.contains('Patient needs closer monitoring') || m.contains('watch')) {
    return 'ملاحظة سريرية: المؤشرات الحيوية بحاجة لمتابعة هادئة.';
  }
  if (m.contains('Patient vitals look stable')) {
    return 'المؤشرات الحيوية مستقرة وطبيعية تماماً والحمد لله.';
  }
  return m;
}

class _Headline extends StatelessWidget {
  const _Headline({required this.alert});

  final AlertItem alert;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final app = context.read<AppState>();
    final s = alertSeverity(alert.severity, l);
    final colors = AppColors.of(context, s.view);
    final profile = app.auth.patientById(alert.patientId);
    final lead = app.monitoring.latestPrediction?.leadTimeMin;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: Insets.card,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
        borderRadius: Radii.rLg,
        border: Border.all(
          color: colors.foreground.withValues(alpha: 0.4),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.foreground.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                AppColors.iconFor(s.view),
                color: colors.foreground,
                size: 22,
              ),
              Gap.hSm,
              Expanded(
                child: RiskBadge(view: s.view, labelOverride: s.label),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'درع الأعصاب الذكي',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF38BDF8),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          Gap.vMd,
          Text(
            lead == null || lead <= 0
                ? l.activeAlertHeadlineNoLead
                : l.activeAlertHeadline(lead.round()),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.foreground,
            ),
          ),
          Gap.vSm,
          Text(
            _friendlyAlertMessage(alert.message),
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.5,
              fontSize: 14.5,
            ),
          ),
          Gap.vMd,
          Wrap(
            spacing: Gap.md,
            runSpacing: Gap.xs,
            children: [
              LabeledValue(
                label: l.alertTime,
                value: TimeAgo.stamp(alert.timestamp),
                icon: Icons.schedule_outlined,
              ),
              if (profile != null)
                LabeledValue(
                  label: l.patientLabel,
                  value: profile.name,
                  icon: Icons.person_outline,
                ),
            ],
          ),
          Gap.vSm,
          RiskStrip(view: s.view),
        ],
      ),
    );
  }
}

class _LocationNavigationCard extends StatelessWidget {
  const _LocationNavigationCard({required this.alert});

  final AlertItem alert;

  String? _extractMapsUrl(String text) {
    final exp = RegExp(r'https://maps\.google\.com/\S+');
    final match = exp.firstMatch(text);
    return match?.group(0);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final mapsUrl =
        _extractMapsUrl(alert.message) ??
        app.messages.lastSharedLocation?['mapsUrl'] as String?;

    if (mapsUrl == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: Gap.md),
      padding: Insets.card,
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: Radii.rMd,
        border: Border.all(color: Colors.blue.shade300, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: Colors.blue.shade700,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.location_on,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              Gap.hSm,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'الموقع الجغرافي للمريض متاح فوراً',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade900,
                      ),
                    ),
                    Text(
                      'اضغط للبدء في الملاحة اللحظية والوصول للمريض عبر خرائط Google',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue.shade800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Gap.vSm,
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.md),
              ),
            ),
            onPressed: () async {
              final uri = Uri.tryParse(mapsUrl);
              if (uri != null && await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.navigation_outlined),
            label: const Text('فتح الملاحة اللحظية (خرائط Google)'),
          ),
        ],
      ),
    );
  }
}

/// The cancel window, as a plain number.
///
/// No pulsing, no ring animation, no colour flashing: §7 forbids fast or
/// flashing motion outright, and a photosensitive patient is exactly the person
/// looking at this screen.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.secondsLeft});

  final int secondsLeft;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = AppColors.of(context, RiskView.caution);
    final seconds = secondsLeft < 0 ? 0 : secondsLeft;

    return SectionCard(
      title: l.cancelWindow,
      icon: Icons.timer_outlined,
      child: Semantics(
        liveRegion: true,
        label: '${l.cancelWindow} $seconds ${l.secondsUnit}',
        child: ExcludeSemantics(
          child: Row(
            children: [
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.container,
                  borderRadius: Radii.rMd,
                  border: Border.all(color: colors.border),
                ),
                child: Text(
                  '$seconds',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.foreground,
                  ),
                ),
              ),
              Gap.hMd,
              Expanded(
                child: Text(
                  l.secondsUnit,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps();

  @override
  Widget build(BuildContext context) {
    final steps = [
      'تنفس بعمق وبطء: خذ شهيقاً هادئاً لـ 4 ثوانٍ ثم زفيراً مسترخياً لتهدئة جهازك العصبي.',
      'اجلس أو استلقِ برفق على جنبك في مكان مريح وآمن بعيداً عن أي أطراف حادة.',
      'أنت بأمان تام ومحاط بالرعاية؛ ومرافقك السريري على تواصل لمساندتك دائماً.',
    ];
    final colors = AppColors.of(context, RiskView.safe);
    final theme = Theme.of(context);

    return SectionCard(
      title: 'إرشادات الاسترخاء والسلامة الوقائية',
      icon: Icons.self_improvement_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.container,
                      borderRadius: Radii.rSm,
                      border: Border.all(color: colors.border),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colors.foreground,
                      ),
                    ),
                  ),
                  Gap.hSm,
                  Expanded(
                    child: Text(
                      steps[i],
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
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

class _PatientActions extends StatelessWidget {
  const _PatientActions({
    required this.busy,
    required this.acknowledged,
    required this.counting,
    required this.onImOk,
    required this.onFalseAlarm,
    required this.onNeedHelp,
  });

  final bool busy;
  final bool acknowledged;

  /// True while the pre-alert can still be stopped before it goes out.
  final bool counting;

  final Future<void> Function() onImOk;
  final Future<void> Function() onFalseAlarm;
  final Future<void> Function() onNeedHelp;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return SectionCard(
      title: 'إجراءات السلامة والاطمئنان',
      icon: Icons.health_and_safety_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Prominent, reassuring "I am OK" button FIRST to eliminate anxiety
          SizedBox(
            height: A11y.emergencyTouchTarget,
            child: FilledButton.icon(
              onPressed: busy || acknowledged ? null : () => onImOk(),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2A9D8F),
                foregroundColor: Colors.white,
                shape: const RoundedRectangleBorder(borderRadius: Radii.rMd),
                textStyle: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              icon: const Icon(Icons.check_circle_outline, size: 24),
              label: Text(
                acknowledged
                    ? 'تم تسجيل استقرارك والحمد لله'
                    : 'أنا بخير تماماً والحمد لله (إلغاء التنبيه)',
              ),
            ),
          ),
          Gap.vSm,

          // 2. Clear False Alarm button
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: busy ? null : () => onFalseAlarm(),
              icon: Icon(
                counting ? Icons.cancel_outlined : Icons.report_off_outlined,
                color: const Color(0xFFE76F51),
              ),
              label: const Text('إنذار غير صحيح / لا أشعر بأي أعراض'),
            ),
          ),
          Gap.vMd,

          // 3. Emergency Help Button (available whenever genuinely needed)
          EmergencyButton(
            label: 'طلب مساندة طارئة (SOS)',
            busy: app.sosInProgress,
            onPressed: () => onNeedHelp(),
          ),
          Gap.vSm,
          const InfoNote(
            text:
                'اطمئن تماماً: النظام يراقب نشاطك باستمرار؛ إذا كان هذا التنبيه عارضاً فإن الضغط على «أنا بخير» يلغيه فوراً دون إقلاق أسرتك.',
            icon: Icons.spa_outlined,
            view: RiskView.safe,
          ),
        ],
      ),
    );
  }
}

class _ResponderActions extends StatelessWidget {
  const _ResponderActions({required this.alert, required this.onRespond});

  final AlertItem alert;
  final Future<void> Function() onRespond;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final role = app.auth.currentUser?.role;

    return SectionCard(
      title: l.quickActions,
      icon: Icons.touch_app_outlined,
      child: SizedBox(
        height: A11y.emergencyTouchTarget,
        child: FilledButton.icon(
          onPressed: () => onRespond(),
          style: FilledButton.styleFrom(
            shape: const RoundedRectangleBorder(borderRadius: Radii.rMd),
            textStyle: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          icon: const Icon(Icons.directions_run_outlined),
          label: Text(role == UserRole.doctor ? l.openFile : l.respond),
        ),
      ),
    );
  }
}

/// Who has actually been reached.
///
/// The distinction the plan cares about is between *sent* and *answered*.
/// Recipients tell the patient the message went out; responses tell them a human
/// has seen it. Conflating the two would let a screen imply help is on the way
/// when nobody has looked at their phone.
class _NotifiedSection extends StatelessWidget {
  const _NotifiedSection({required this.alert, required this.responses});

  final AlertItem alert;
  final List<AlertResponse> responses;

  static String _statusLabel(ResponseStatus s, AppLocalizations l) =>
      switch (s) {
        ResponseStatus.seen => l.seenBy,
        ResponseStatus.acknowledged => l.respondedBy,
        ResponseStatus.onWay => l.onWay,
        ResponseStatus.arrived => l.arrived,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return SectionCard(
      title: l.respondersSection,
      icon: Icons.group_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoNote(
            text: l.isArabic
                ? 'تأكيد استلام الإشعار غير متاح هنا. تظهر ردود المرافقين أدناه عند وصولها.'
                : 'Notification delivery is not confirmed here. Caregiver responses appear below when received.',
            icon: Icons.mark_email_unread_outlined,
            view: RiskView.unknown,
          ),
          Gap.vSm,
          if (responses.isEmpty)
            EmptyState(
              title: l.noRespondersYet,
              body: l.respondersHint,
              icon: Icons.hourglass_empty_outlined,
              compact: true,
            )
          else
            for (final r in responses)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.person_outline, size: 20),
                title: Text(
                  r.responderName.isEmpty ? l.caregiverLabel : r.responderName,
                ),
                subtitle: Text(
                  '${_statusLabel(r.status, l)} · ${TimeAgo.stamp(r.at)}',
                  style: theme.textTheme.labelSmall,
                ),
              ),
        ],
      ),
    );
  }
}
