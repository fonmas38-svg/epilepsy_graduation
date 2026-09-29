import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/risk_indicator.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../services/medication_service.dart';
import '../../services/monitoring_service.dart';
import '../../widgets/lead_time_card.dart';
import '../../widgets/prediction_gauge.dart';
import '../../widgets/signal_chart.dart';
import '../shared/alerts_list.dart';
import 'device_link_screen.dart';
import 'emergency_plan_screen.dart';
import 'history_screen.dart';
import 'medication_screen.dart';
import '../../widgets/app_drawer.dart';

/// §3.1 — the patient's shell: five destinations, one of which is the dashboard.
///
/// Decisions worth stating, because each one is a place the obvious choice is
/// wrong:
///
/// * **Five destinations, and the device is not one of them.** The plan names six
///   tabs, but a bottom bar with six items is unreadable at large text scales and
///   pairing the headband — a one-off setup task — does not deserve permanent
///   space next to «الطوارئ». The device lives as a card on the dashboard that
///   opens [DeviceLinkScreen]; `l.tabDevice` stays in the string table for it.
/// * **An [IndexedStack], not a rebuilt body.** Switching to «الدواء» and back
///   must not reset the history screen's scroll position or re-run its queries.
/// * **Each destination keeps its own `AppBar`.** They are also reachable as
///   routes (from a notification, or the settings screen), and a screen that
///   loses its title depending on how it was opened is a screen that has to be
///   written twice.
/// * **No status is invented.** Everything the dashboard shows about risk comes
///   from [AppState.riskView], which already refuses to show a stale or
///   sensor-less reading as «آمن» (§11.1). Two fields the plan asks for —
///   battery and signal quality — have no source in `DeviceStatusResult`, so
///   they are absent rather than filled with a plausible number.
class PatientHomeScreen extends StatefulWidget {
  const PatientHomeScreen({super.key});

  @override
  State<PatientHomeScreen> createState() => _PatientHomeScreenState();
}

class _PatientHomeScreenState extends State<PatientHomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_tab != 0) {
          setState(() => _tab = 0);
          return;
        }
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l.exitConfirmTitle),
            content: Text(l.exitConfirmMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.keepInBackground),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l.exitApp),
              ),
            ],
          ),
        );
        if (shouldExit == true && context.mounted) {
          await app.signOut();
          if (context.mounted) {
            Navigator.pushNamedAndRemoveUntil(context, Routes.login, (r) => false);
          }
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab,
          children: const [
            _DashboardTab(),
            _AlertsTab(),
            MedicationScreen(),
            PatientHistoryScreen(),
            EmergencyPlanScreen(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.favorite_outline),
            selectedIcon: const Icon(Icons.favorite),
            label: l.tabHome,
          ),
          NavigationDestination(
            icon: const Icon(Icons.notifications_none_outlined),
            selectedIcon: const Icon(Icons.notifications),
            label: l.tabAlerts,
          ),
          NavigationDestination(
            icon: const Icon(Icons.medication_outlined),
            selectedIcon: const Icon(Icons.medication),
            label: l.tabMeds,
          ),
          NavigationDestination(
            icon: const Icon(Icons.timeline_outlined),
            selectedIcon: const Icon(Icons.timeline),
            label: l.tabHistory,
          ),
          NavigationDestination(
            // Outlined *and* filled are the same glyph here on purpose: the
            // emergency destination should look identical whether or not it is
            // selected, so it is recognisable by shape alone.
            icon: const Icon(Icons.emergency_outlined),
            selectedIcon: const Icon(Icons.emergency),
            label: l.tabEmergency,
          ),
        ],
      ),
    ),
  );
}
}

/// The «حالتي» dashboard.
class _DashboardTab extends StatefulWidget {
  const _DashboardTab();

  @override
  State<_DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<_DashboardTab> {
  /// Today's doses. Loaded once and re-read after a dose is recorded; the *next*
  /// dose is derived from it on every build, so it advances with the clock
  /// without another query.
  List<ScheduleEntry> _schedule = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _loadSchedule();
  }

  Future<void> _loadSchedule() async {
    final app = context.read<AppState>();
    final pid = app.activePatientId;
    if (pid == null) return;
    try {
      final entries = await app.medication.todaySchedule(pid);
      if (!mounted) return;
      setState(() => _schedule = entries);
    } catch (_) {
      // A missing dose plan must not take the status card down with it.
    }
  }

  /// The dose the patient should be thinking about: the earliest untaken one
  /// still to come today, or — if the day's plan is already behind — the earliest
  /// untaken one at all, because a missed 08:00 is more useful to show at noon
  /// than «لا توجد جرعة قريبة».
  ScheduleEntry? get _nextDose {
    final pending = _schedule.where((e) => !e.taken).toList();
    if (pending.isEmpty) return null;
    final now = TimeAgo.clock(DateTime.now());
    for (final e in pending) {
      if (e.time.compareTo(now) >= 0) return e;
    }
    return pending.first;
  }

  Future<void> _sos() async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.needHelpConfirmTitle),
        content: Text(l.needHelpConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.send),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await app.triggerSos();
    if (!mounted) return;
    // `triggerSos` records the reason in `AppState.failure` instead of throwing,
    // so success is judged by whether an alert came back — not by the absence of
    // an exception.
    if (app.failure != null) {
      AppSnack.error(context, l.sosFailed);
      app.clearFailure();
    } else {
      AppSnack.success(context, l.sosSent);
    }
  }

  Future<void> _takeDose(ScheduleEntry entry) async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await app.medication.markTaken(
        entry.medication,
        scheduledFor: _at(entry.time),
      );
      await _loadSchedule();
      if (!mounted) return;
      AppSnack.success(context, l.doseTaken);
    } catch (_) {
      if (!mounted) return;
      AppSnack.error(context, l.errUnknown);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Today at `HH:mm`. The log stores the time the dose was *due*, not the time
  /// the button was pressed, so a dose taken late still settles the right slot.
  DateTime _at(String hhmm) {
    final now = DateTime.now();
    final parts = hhmm.split(':');
    final h = int.tryParse(parts.first) ?? 0;
    final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return DateTime(now.year, now.month, now.day, h, m);
  }

  void _openAlert(AlertItem alert) => Navigator.pushNamed(
    context,
    Routes.alert,
    arguments: AlertRouteArgs(alertId: alert.id, patientId: alert.patientId),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final name = app.auth.currentUser?.name ?? '';
    final pre = app.preAlert;
    final prediction = app.monitoring.latestPrediction;

    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'منظومة مراقبة الصرع الذكية',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
            ),
            const SizedBox(height: 2),
            Text(
              name.isEmpty ? 'مرحباً بك' : 'مرحباً $name',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
        actions: [
          // Demo-only. On a real build a patient must not be able to fabricate
          // a high-risk reading — the people it would notify cannot tell the
          // difference (§11.1).
          if (AppConfig.demoMode &&
              app.monitoring.source != SignalSource.headDevice)
            IconButton(
              tooltip: l.demoHighRisk,
              onPressed: app.forceHighRiskDemo,
              icon: const Icon(Icons.science_outlined),
            ),
          IconButton(
            tooltip: 'مشاركة الموقع المباشر مع الأسرة',
            onPressed: () async {
              final ok = await app.shareMyLocationWithFamily();
              if (context.mounted) {
                ok
                    ? AppSnack.success(context, 'تم إرسال موقعك للأسرة بنجاح')
                    : AppSnack.error(context, 'تعذّر تحديد أو إرسال الموقع');
              }
            },
            icon: const Icon(Icons.my_location_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadSchedule,
        child: ResponsiveContent(
          maxWidth: 850,
          child: ListView(
            padding: Insets.pageBottomSafe,
            children: [
              OfflineBanner(
                visible: !app.apiOnline,
                lastUpdateLabel: TimeAgo.since(app.lastObservedAt, l),
                pendingCount: app.care.pendingCount,
              ),
              RiskGauge(
                view: app.riskView,
                leadTimeMin: prediction?.leadTimeMin,
                freshnessLabel:
                    '${l.lastUpdate}: ${TimeAgo.since(app.lastObservedAt, l)}',
                reasonLabel: l.riskUnknownWhy,
              ),
              if (pre != null) ...[
                Gap.vMd,
                _PreAlertCard(
                  alert: pre,
                  leadTimeMin: prediction?.leadTimeMin,
                  onOpen: () => _openAlert(pre),
                ),
              ],
              Gap.vLg,
              // Below the status, above everything else, and never behind a tab.
              EmergencyButton(
                onPressed: app.sosInProgress ? null : _sos,
                busy: app.sosInProgress,
              ),
              Gap.vLg,
              const _FamilyLocationCard(),
              Gap.vMd,
              const _SimulatorBannerCard(),
              Gap.vMd,
              _NextDoseSection(
                entry: _nextDose,
                enabled: !_busy,
                onTake: _takeDose,
              ),
              Gap.vMd,
              _DeviceSection(monitoring: app.monitoring),
              Gap.vMd,
              _SourceSection(app: app),
              if (prediction != null) ...[
                Gap.vMd,
                PredictionGauge(prediction: prediction),
                Gap.vMd,
                LeadTimeCard(prediction: prediction),
              ],
              Gap.vMd,
              _SignalSection(reading: app.monitoring.latestReading),
              Gap.vMd,
              _RecentAlertsSection(
                alerts: app.monitoring.alerts,
                onAcknowledge: app.acknowledgeAlert,
                onOpen: _openAlert,
              ),
              Gap.vMd,
              const _QuickActionsSection(),
            ],
          ),
        ),
      ),
    );
  }
}

/// A live pre-alert, surfaced on the dashboard so it is not missed by a patient
/// who dismissed the notification.
///
/// No countdown is drawn here. The cancel window is owned by the active-alert
/// screen, and a second timer on the dashboard would eventually disagree with it
/// — two different numbers for «الوقت المتبقي» is worse than one.
class _PreAlertCard extends StatelessWidget {
  const _PreAlertCard({
    required this.alert,
    required this.leadTimeMin,
    required this.onOpen,
  });

  final AlertItem alert;
  final double? leadTimeMin;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = AppColors.of(context, RiskView.caution);
    final headline = leadTimeMin != null && leadTimeMin! > 0
        ? 'مؤشرات تغير طفيفة في النشاط — احتمالية نوبة خلال ~${leadTimeMin!.round()} دقيقة'
        : 'رصد نشاط عصبي غير معتاد — نوصيك بالجلوس والاسترخاء';

    return Container(
      padding: Insets.card,
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: Radii.rMd,
        border: Border.all(color: tone.border, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.self_improvement_outlined, color: tone.foreground),
              Gap.hSm,
              Expanded(
                child: Text(
                  'ملاحظة وقائية استباقية — تنفس بهدوء',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: tone.foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          Gap.vXs,
          Text(
            headline,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tone.foreground,
              height: 1.4,
            ),
          ),
          Gap.vSm,
          SizedBox(
            height: A11y.minTouchTarget,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: tone.solid,
                foregroundColor: tone.onSolid,
              ),
              onPressed: onOpen,
              icon: const Icon(Icons.spa_outlined),
              label: const Text('عرض إرشادات الاسترخاء والسلامة والاطمئنان'),
            ),
          ),
        ],
      ),
    );
  }
}

class _NextDoseSection extends StatelessWidget {
  const _NextDoseSection({
    required this.entry,
    required this.enabled,
    required this.onTake,
  });

  final ScheduleEntry? entry;
  final bool enabled;
  final Future<void> Function(ScheduleEntry) onTake;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final e = entry;

    return SectionCard(
      title: l.nextDose,
      icon: Icons.medication_outlined,
      child: e == null
          ? Text(
              l.noDoseDue,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.medication.dosage.isEmpty
                            ? e.medication.name
                            : '${e.medication.name} · ${e.medication.dosage}',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        e.time,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Gap.hSm,
                SizedBox(
                  height: A11y.minTouchTarget,
                  child: FilledButton.icon(
                    onPressed: enabled ? () => onTake(e) : null,
                    icon: const Icon(Icons.check),
                    label: Text(l.takeDose),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Headband state — only what the gateway actually reports.
///
/// `battery` and `signalQuality` are deliberately missing: `/device/status`
/// returns connection, buffered sample count and a last-seen timestamp, and
/// nothing else. Showing «البطارية: ٨٠٪» from no data would be a fabrication on
/// the one screen a patient uses to decide whether to trust the system.
class _DeviceSection extends StatelessWidget {
  const _DeviceSection({required this.monitoring});

  final MonitoringService monitoring;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isDevice = monitoring.source == SignalSource.headDevice;
    final lastSeen = DateTime.tryParse(monitoring.lastDeviceSeen ?? '');

    // Outside head-device mode the app is not polling the headband, so its state
    // is genuinely unknown — not «غير متصل».
    final (RiskView view, String status) = !isDevice
        ? (RiskView.unknown, l.unknown)
        : monitoring.deviceConnected
        ? (RiskView.safe, l.deviceConnected)
        : lastSeen != null
        ? (RiskView.caution, l.deviceWaiting)
        : (RiskView.caution, l.deviceDisconnected);

    return SectionCard(
      title: l.deviceSection,
      icon: Icons.sensors,
      trailing: RiskBadge(view: view, labelOverride: status, dense: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (monitoring.deviceId != null)
            LabeledValue(
              label: l.deviceSection,
              value: monitoring.deviceId!,
              icon: Icons.tag,
            ),
          LabeledValue(
            label: l.bufferedSamples,
            value: '${monitoring.deviceBuffered}',
            icon: Icons.data_usage_outlined,
          ),
          LabeledValue(
            label: l.lastUpdate,
            value: TimeAgo.since(lastSeen, l),
            icon: Icons.schedule,
          ),
          Gap.vSm,
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DeviceLinkScreen()),
              ),
              icon: const Icon(Icons.link),
              label: Text(l.manageDevice),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where the numbers on this screen come from, and which engine produced them.
///
/// Switching the source is a demo control, so it only appears in a demo build. A
/// patient on a real install sees the source stated and cannot change it: an app
/// that lets you point a medical display at a simulator is an app whose green
/// badge means nothing.
class _SourceSection extends StatelessWidget {
  const _SourceSection({required this.app});

  final AppState app;

  static String _sourceLabel(SignalSource s, AppLocalizations l) => switch (s) {
    SignalSource.simulator => l.sourceSimulator,
    SignalSource.dataset => l.sourceDataset,
    SignalSource.headDevice => l.sourceDevice,
  };

  static String _engineLabel(String? engine, AppLocalizations l) =>
      switch (engine) {
        'cnn_lstm_fusion' => l.engineDeep,
        'sklearn' => l.engineSklearn,
        null => l.notSet,
        _ => l.engineRules,
      };

  Future<void> _select(SignalSource s) => switch (s) {
    SignalSource.simulator => app.useSimulator(),
    SignalSource.dataset => app.useDataset(),
    SignalSource.headDevice => app.useHeadDevice(),
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final current = app.monitoring.source;

    return SectionCard(
      title: l.sourceSection,
      icon: Icons.input,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!AppConfig.demoMode)
            LabeledValue(
              label: l.sourceSection,
              value: _sourceLabel(current, l),
              icon: Icons.input,
            )
          else
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final s in SignalSource.values)
                  ChoiceChip(
                    label: Text(_sourceLabel(s, l)),
                    selected: s == current,
                    onSelected: (_) => s == current ? null : _select(s),
                  ),
              ],
            ),
          Gap.vSm,
          LabeledValue(
            label: l.engineLabel,
            value: _engineLabel(app.activeEngine, l),
            icon: Icons.memory,
          ),
          if (!app.apiOnline) ...[
            Gap.vSm,
            // Said plainly, because the engine name above is the *last* one the
            // server reported, not necessarily the one in use now.
            InfoNote(
              text: l.offlineNoData,
              icon: Icons.cloud_off_outlined,
              view: RiskView.caution,
            ),
          ],
        ],
      ),
    );
  }
}

/// The raw window, kept for the demo and for a patient who wants to see that
/// something is genuinely being measured. Deliberately near the bottom: nobody
/// should have to read an EEG trace to learn how they are.
class _SignalSection extends StatelessWidget {
  const _SignalSection({required this.reading});

  final VitalReading? reading;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final r = reading;

    return SectionCard(
      title: l.signalWindowSection,
      icon: Icons.show_chart,
      child: r == null
          ? Text(
              l.offlineNoData,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledValue(
                  label: l.driverHr,
                  value: '${r.hr.toStringAsFixed(0)} bpm',
                  icon: Icons.favorite_outline,
                ),
                Gap.vSm,
                SignalChart(
                  title: l.driverEeg,
                  values: r.eeg,
                  color: AppColors.signalEeg(theme.brightness),
                ),
                Gap.vSm,
                SignalChart(
                  title: l.driverEcg,
                  values: r.ecg,
                  color: AppColors.signalEcg(theme.brightness),
                ),
                Gap.vSm,
                SignalChart(
                  title: l.driverMotion,
                  values: r.motion,
                  color: AppColors.signalMotion(theme.brightness),
                ),
              ],
            ),
    );
  }
}

/// The three most recent alerts, with the full list one tap away.
///
/// Three, not all of them: this section exists to answer «هل فاتني شيء؟». The
/// «التنبيهات» destination is where the record lives.
class _RecentAlertsSection extends StatelessWidget {
  const _RecentAlertsSection({
    required this.alerts,
    required this.onAcknowledge,
    required this.onOpen,
  });

  final List<AlertItem> alerts;
  final Future<void> Function(String id) onAcknowledge;
  final void Function(AlertItem alert) onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SectionCard(
      title: l.alertsTitle,
      icon: Icons.notifications_none_outlined,
      child: AlertsList(
        alerts: alerts.take(3).toList(),
        onAcknowledge: onAcknowledge,
        onOpen: onOpen,
        padding: EdgeInsets.zero,
        shrinkWrap: true,
      ),
    );
  }
}

/// The §3 screens that are not destinations: diary, consents, settings.
class _QuickActionsSection extends StatelessWidget {
  const _QuickActionsSection();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SectionCard(
      title: l.quickActions,
      icon: Icons.apps_outlined,
      child: Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.sm,
        children: [
          const _Action(
            icon: Icons.table_chart_outlined,
            label: 'التقارير وتصدير Excel',
            route: Routes.reports,
          ),
          const _Action(
            icon: Icons.chat_bubble_outline,
            label: 'توجيهات ورسائل الطبيب',
            route: Routes.messages,
          ),
          _Action(
            icon: Icons.event_note_outlined,
            label: l.triggersTitle,
            route: Routes.patientTriggers,
          ),
          _Action(
            icon: Icons.privacy_tip_outlined,
            label: l.consentsTitle,
            route: Routes.patientConsents,
          ),
          _Action(
            icon: Icons.settings_outlined,
            label: l.settings,
            route: Routes.patientSettings,
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.route,
  });

  final IconData icon;
  final String label;
  final String route;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: A11y.minTouchTarget,
    child: OutlinedButton.icon(
      onPressed: () => Navigator.pushNamed(context, route),
      icon: Icon(icon),
      label: Text(label),
    ),
  );
}

/// The «التنبيهات» destination: the whole list, acknowledgeable, tappable.
class _AlertsTab extends StatelessWidget {
  const _AlertsTab();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(title: Text(l.alertsTitle)),
      body: Column(
        children: [
          OfflineBanner(
            visible: !app.apiOnline,
            pendingCount: app.care.pendingCount,
          ),
          Expanded(
            child: AlertsList(
              alerts: app.monitoring.alerts,
              onAcknowledge: app.acknowledgeAlert,
              onOpen: (a) => Navigator.pushNamed(
                context,
                Routes.alert,
                arguments: AlertRouteArgs(alertId: a.id, patientId: a.patientId),
              ),
              padding: Insets.pageBottomSafe,
            ),
          ),
        ],
      ),
    );
  }
}

class _FamilyLocationCard extends StatefulWidget {
  const _FamilyLocationCard();

  @override
  State<_FamilyLocationCard> createState() => _FamilyLocationCardState();
}

class _FamilyLocationCardState extends State<_FamilyLocationCard> {
  bool _sharing = false;

  Future<void> _share(AppState app) async {
    setState(() => _sharing = true);
    final ok = await app.shareMyLocationWithFamily();
    if (!mounted) return;
    setState(() => _sharing = false);
    if (ok) {
      AppSnack.success(context, 'تم إرسال وتحديث موقعك الجغرافي لأفراد أسرتك بنجاح.');
    } else {
      AppSnack.error(context, 'تعذّر تحديد الموقع. يرجى التأكد من تفعيل الـ GPS ومنح الصلاحيات.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final lastLoc = app.messages.lastSharedLocation;

    return Container(
      padding: Insets.card,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: Radii.rMd,
        border: Border.all(color: Colors.teal.withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.location_on, color: Colors.teal, size: 22),
              ),
              Gap.hSm,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'مشاركة الموقع مع الأسرة لسلامتك',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'مهم جداً: يتيح لعائلتك معرفة مكانك فوراً وإسعافك عند حدوث نوبة.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Gap.vSm,
          if (lastLoc != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: Colors.teal.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, size: 14, color: Colors.teal),
                  Gap.hXs,
                  Expanded(
                    child: Text(
                      'آخر موقع مسجل: ${(lastLoc['latitude'] as num).toStringAsFixed(4)}, ${(lastLoc['longitude'] as num).toStringAsFixed(4)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.teal.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Gap.vSm,
          ],
          SizedBox(
            width: double.infinity,
            height: A11y.minTouchTarget,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.teal,
                foregroundColor: Colors.white,
              ),
              onPressed: _sharing ? null : () => _share(app),
              icon: _sharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.my_location),
              label: Text(_sharing ? 'جارٍ تحديد وإرسال الموقع...' : 'إرسال وتحديث موقعي للأسرة الآن'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SimulatorBannerCard extends StatelessWidget {
  const _SimulatorBannerCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => Navigator.pushNamed(context, Routes.patientSimulator),
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: Insets.card,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.primaryContainer.withValues(alpha: 0.7),
              theme.colorScheme.surface,
            ],
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
          borderRadius: Radii.rMd,
          border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.monitor_heart, color: Colors.white, size: 22),
            ),
            Gap.hMd,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'محاكي الإشارات الحيوية والتصعيد',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Text(
                    'عرض نبض القلب الحي، تخطيط موجات الدماغ EEG، وتصعيد درجات التنبيه.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, size: 14, color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

