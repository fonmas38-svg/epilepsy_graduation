import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/router/route_names.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/risk_indicator.dart';
import '../../core/ui/workspace_scaffold.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../services/connectivity_coordinator.dart';
import '../../services/location_service.dart';
import '../../services/medication_service.dart';
import '../../services/monitoring_service.dart';
import '../../widgets/lead_time_card.dart';
import '../../widgets/battery_exemption_notice.dart';
import '../../widgets/emergency_contacts_warning.dart';
import '../../widgets/monitoring_capability_notice.dart';
import '../../widgets/prediction_gauge.dart';
import '../../widgets/signal_chart.dart';
import '../shared/account_screen.dart';
import '../shared/alerts_list.dart';
import 'device_link_screen.dart';
import 'history_screen.dart';
import 'medication_screen.dart';

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
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_tab != 0) {
          setState(() => _tab = 0);
          return;
        }
      },
      child: WorkspaceScaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            _DashboardTab(onSelectTab: (i) => setState(() => _tab = i)),
            const _AlertsTab(),
            const MedicationScreen(),
            const PatientHistoryScreen(),
            const AccountScreen(embedded: true),
          ],
        ),
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            label: l.tabHome,
          ),
          NavigationDestination(
            icon: const Icon(Icons.notifications_none),
            label: l.tabAlerts,
          ),
          NavigationDestination(
            icon: const Icon(Icons.medication_outlined),
            label: l.tabMeds,
          ),
          NavigationDestination(
            icon: const Icon(Icons.history),
            label: l.tabHistory,
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            label: l.isArabic ? 'حسابي' : 'Account',
          ),
        ],
      ),
    );
  }
}

/// The «حالتي» dashboard.
class _DashboardTab extends StatefulWidget {
  const _DashboardTab({this.onSelectTab});

  final ValueChanged<int>? onSelectTab;

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
  /// still to come today, or — if the day's plan is already behind — the most
  /// recent untaken one, because a just-missed 20:00 is more useful to show at
  /// 20:15 than this morning's 08:00 or «لا توجد جرعة قريبة».
  ScheduleEntry? get _nextDose {
    final pending = _schedule.where((e) => !e.taken).toList();
    if (pending.isEmpty) return null;
    // Same 24-hour «HH:mm» form as the schedule, so the comparison holds
    // (the 12-hour display string sorted wrongly against «20:00»).
    final clock = DateTime.now();
    final now =
        '${clock.hour.toString().padLeft(2, '0')}:'
        '${clock.minute.toString().padLeft(2, '0')}';
    for (final e in pending) {
      if (e.time.compareTo(now) >= 0) return e;
    }
    return pending.last;
  }

  Future<void> _sos() async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    // Promise only what will happen: offline, the alert goes out by SMS to
    // the emergency contacts, and with none there is nobody to reach.
    final online = app.operatingMode == AppOperatingMode.onlineFull;
    var hasContacts = true;
    if (!online) {
      try {
        hasContacts = (await app.validEmergencyContacts()).isNotEmpty;
      } catch (_) {}
      if (!mounted) return;
    }
    final body = online
        ? l.needHelpConfirmBody
        : hasContacts
        ? (l.isArabic
              ? 'لا يوجد إنترنت: ستُجهَّز رسالة نصية (SMS) بموقعك إلى أرقام الطوارئ لترسلها.'
              : 'No internet: a text message (SMS) with your location will be prepared for your emergency contacts.')
        : (l.isArabic
              ? 'لا يوجد إنترنت ولا أرقام طوارئ: لن يصل التنبيه إلى أحد من هذا الهاتف. اتصل بالإسعاف مباشرة إن احتجت.'
              : 'No internet and no emergency numbers: this phone cannot alert anyone. Call emergency services directly if needed.');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.needHelpConfirmTitle),
        content: Text(body),
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

  void _showMoreServicesSheet(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    showModalBottomSheet<void>(
      context: context,
      // Scrollable: at large text sizes the rows never overflow the sheet.
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                ar ? 'الأدوات والخدمات' : 'Tools & Services',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              // «خطة الطوارئ» and «المحفزات» are quick actions on Home; the
              // sheet lists only tools not already one tap away.
              ListTile(
                leading: const ToneIcon(
                  icon: Icons.devices_outlined,
                  tone: AccentTone.green,
                ),
                title: Text(
                  ar ? 'رباط الرأس والسوار الذكي' : 'Wearable Headband Device',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.pushNamed(context, Routes.patientDevice);
                },
              ),
              ListTile(
                leading: const ToneIcon(
                  icon: Icons.picture_as_pdf_outlined,
                  tone: AccentTone.blue,
                ),
                title: Text(
                  ar ? 'التقارير الطبية السريرية' : 'Clinical Medical Reports',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.pushNamed(context, Routes.reports);
                },
              ),
              ListTile(
                leading: const ToneIcon(
                  icon: Icons.security_outlined,
                  tone: AccentTone.slate,
                ),
                title: Text(
                  ar ? 'صلاحيات وأذونات النظام' : 'Device & System Permissions',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.pushNamed(context, Routes.devicePermissions);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final pre = app.preAlert;
    final prediction = app.monitoring.latestPrediction;
    final userName = app.auth.currentUser?.name ?? '';

    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadSchedule,
                child: ResponsiveContent(
                  maxWidth: 850,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                    children: [
                      _DashboardTopHeader(
                        userName: userName,
                        onMenu: () => Scaffold.maybeOf(context)?.openDrawer(),
                        onProfile: () =>
                            Navigator.pushNamed(context, Routes.account),
                      ),
                      Gap.vMd,
                      OfflineBanner(
                        visible: !app.apiOnline,
                        mode: app.operatingMode,
                        onSyncNow: app.syncNow,
                        lastUpdateLabel: TimeAgo.since(app.lastObservedAt, l),
                        pendingCount: app.care.pendingCount,
                      ),
                      // Pre-alert first: it has a 30-second cancel window.
                      if (pre != null) ...[
                        Gap.vMd,
                        _PreAlertCard(
                          alert: pre,
                          leadTimeMin: prediction?.leadTimeMin,
                          onOpen: () => _openAlert(pre),
                        ),
                      ],
                      // Only actionable notices on Home. The model/server capability
                      // explanation lives on the Monitoring screen, where it applies.
                      EmergencyContactsWarning(
                        app: app,
                        otherwise: BatteryExemptionNotice(
                          background: app.background,
                        ),
                      ),
                      Gap.vSm,
                      _SmartMonitoringHeroCard(
                        monitoring: app.monitoring,
                        onTap: () => Navigator.pushNamed(
                          context,
                          Routes.patientMonitoring,
                        ),
                        onToggle: app.setMonitoringEnabled,
                      ),
                      // The most frequent daily action, right under the status.
                      Gap.vMd,
                      _NextDoseSection(
                        entry: _nextDose,
                        enabled: !_busy,
                        onTake: _takeDose,
                      ),
                      Gap.vMd,
                      _SeizureProbabilityCard(
                        riskView: app.riskView,
                        observedAt: app.lastObservedAt,
                        probability: prediction?.preictalProb,
                        leadTimeMin: prediction?.leadTimeMin,
                      ),
                      Gap.vMd,
                      // Daily actions not already in the bottom bar (history and
                      // alerts are tabs; live monitoring is the card above).
                      _PastelQuickActionsRow(
                        onAddRecord: () =>
                            Navigator.pushNamed(context, Routes.patientEntry),
                        onEmergencyPlan: () => Navigator.pushNamed(
                          context,
                          Routes.patientEmergency,
                        ),
                        onTriggers: () => Navigator.pushNamed(
                          context,
                          Routes.patientTriggers,
                        ),
                        onMore: () => _showMoreServicesSheet(context),
                      ),
                      Gap.vMd,
                      _RecentActivitiesSection(
                        latestAlert: app.monitoring.alerts.isNotEmpty
                            ? app.monitoring.alerts.first
                            : null,
                        lastObservedAt: app.lastObservedAt,
                        onViewAll: () {
                          if (widget.onSelectTab != null) {
                            widget.onSelectTab!(1);
                          }
                        },
                      ),
                      if (app.monitoring.alerts.isNotEmpty) ...[
                        Gap.vMd,
                        _RecentAlertsSection(
                          alerts: app.monitoring.alerts,
                          onAcknowledge: app.acknowledgeAlert,
                          onOpen: _openAlert,
                        ),
                      ],
                      Gap.vMd,
                      const _FamilyLocationCard(),
                      Gap.vMd,
                      const _SimulatorBannerCard(),
                    ],
                  ),
                ),
              ),
            ),
            // SOS pinned: «كبير، ظاهر دائمًا» — never scrolled out of reach,
            // and at the bottom where a trembling thumb lands first.
            Material(
              color: Theme.of(context).colorScheme.surface,
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                // Center: lets maxWidth apply, so on wide screens the bar
                // lines up with the 850 dp content column above it.
                child: Center(
                  // heightFactor 1: in a bottom bar an unbounded Center fills the
                  // whole screen and hides the page.
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 850),
                    child: EmergencyButton(
                      onPressed: app.sosInProgress ? null : _sos,
                      busy: app.sosInProgress,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardTopHeader extends StatelessWidget {
  const _DashboardTopHeader({
    required this.userName,
    required this.onMenu,
    required this.onProfile,
  });

  final String userName;
  final VoidCallback onMenu;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return Row(
      children: [
        IconButton(
          onPressed: onMenu,
          icon: Icon(
            Icons.menu_rounded,
            color: Theme.of(context).colorScheme.onSurface,
            size: 28,
          ),
          tooltip: ar ? 'القائمة' : 'Menu',
        ),
        Gap.hSm,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ar ? 'مرحبًا $userName' : 'Welcome, $userName',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onSurface,
                  letterSpacing: -0.5,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                ar
                    ? 'معا نحو حياة أكثر أمانا'
                    : 'Together towards a safer life',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Gap.hSm,
        GestureDetector(
          onTap: onProfile,
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: AppColors.accent(context, AccentTone.blue).container,
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 1.5,
              ),
            ),
            child: Icon(
              Icons.person_outline_rounded,
              color: AppColors.accent(context, AccentTone.blue).foreground,
              size: 26,
            ),
          ),
        ),
      ],
    );
  }
}

class _SmartMonitoringHeroCard extends StatelessWidget {
  const _SmartMonitoringHeroCard({
    required this.monitoring,
    required this.onTap,
    this.onToggle,
  });

  final MonitoringService monitoring;
  final VoidCallback onTap;

  /// Starts/stops monitoring. A visible labelled button: the card itself only
  /// opens the monitoring screen, which was easy to miss as «how to start».
  final Future<void> Function(bool enable)? onToggle;

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF003B94), Color(0xFF0056D2), Color(0xFF0070F3)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0056D2).withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Stack(
            children: [
              Positioned.directional(
                textDirection: Directionality.of(context),
                end: -10,
                bottom: -10,
                top: -10,
                width: 170,
                child: IgnorePointer(
                  child: CustomPaint(painter: BrainEegPainter(isArabic: ar)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            // Green «live» dot only while monitoring really
                            // runs; a static grey dot (no glow) when stopped.
                            color: monitoring.running
                                ? const Color(0xFF00E676)
                                : const Color(0xFFB0BEC5),
                            shape: BoxShape.circle,
                            boxShadow: [
                              if (monitoring.running)
                                BoxShadow(
                                  color: const Color(
                                    0xFF00E676,
                                  ).withValues(alpha: 0.8),
                                  blurRadius: 8,
                                  spreadRadius: 2,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Expanded: long titles (English, large text) wrap
                        // instead of overflowing past the arrow.
                        Expanded(
                          child: Text(
                            ar
                                ? (monitoring.signalSourceLabel ==
                                          'dataset_cached_replay'
                                      ? 'إعادة عرض محلية'
                                      : monitoring.running
                                      ? 'المراقبة الذكية نشطة'
                                      : 'المراقبة متوقفة')
                                : (monitoring.signalSourceLabel ==
                                          'dataset_cached_replay'
                                      ? 'Offline replay'
                                      : monitoring.running
                                      ? 'Smart Monitoring Active'
                                      : 'Monitoring stopped'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            ar
                                ? Icons.chevron_left_rounded
                                : Icons.chevron_right_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 190),
                      child: Text(
                        ar
                            ? (monitoring.signalSourceLabel ==
                                      'dataset_cached_replay'
                                  ? 'إشارات محفوظة سابقاً\nدون توقع حالي'
                                  : monitoring.running
                                  ? 'يتم تحليل إشارات EEG\nفي الوقت الحقيقي'
                                  : 'ابدأ المراقبة لعرض\nالبيانات المتاحة')
                            : (monitoring.signalSourceLabel ==
                                      'dataset_cached_replay'
                                  ? 'Previously recorded signals\nno current forecast'
                                  : monitoring.running
                                  ? 'Analyzing EEG signals\nin real time'
                                  : 'Start monitoring to see\navailable data'),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.45,
                        ),
                      ),
                    ),
                    if (onToggle != null) ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          // White on the fixed brand gradient in both themes.
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF003B94),
                          minimumSize: const Size(0, A11y.minTouchTarget),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: () => onToggle!(!monitoring.running),
                        icon: Icon(
                          monitoring.running
                              ? Icons.stop_circle_outlined
                              : Icons.play_circle_outline_rounded,
                        ),
                        label: Text(
                          monitoring.running
                              ? (ar ? 'إيقاف المراقبة' : 'Stop monitoring')
                              : (ar ? 'ابدأ المراقبة' : 'Start monitoring'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeizureProbabilityCard extends StatelessWidget {
  const _SeizureProbabilityCard({
    required this.riskView,
    required this.probability,
    this.leadTimeMin,
    this.observedAt,
  });

  final RiskView riskView;
  final double? probability;
  final double? leadTimeMin;
  final DateTime? observedAt;

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';

    final noProbability =
        probability == null ||
        !probability!.isFinite ||
        probability! < 0 ||
        probability! > 1;
    // A classification without a forecast percentage (e.g. recorded data) is
    // still the patient's current status: show it, never «waiting» while the
    // monitoring screen says «high likelihood».
    if (noProbability && !riskView.isUnknown) {
      final l = AppLocalizations.of(context);
      return RiskGauge(
        view: riskView,
        freshnessLabel: observedAt == null
            ? null
            : TimeAgo.since(observedAt, l),
      );
    }
    if (noProbability) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.monitor_heart_outlined),
          title: Text(
            ar
                ? 'بانتظار تحليل إشارة صالحة'
                : 'Waiting for a valid signal analysis',
          ),
          subtitle: Text(
            ar
                ? 'لا توجد نتيجة متاحة لحساب احتمال النوبة.'
                : 'No prediction probability is available.',
          ),
        ),
      );
    }
    final double rawProb = probability!;
    final int percent = (rawProb * 100).round();

    final Color statusColor;
    final String statusLabel;
    final String description;

    switch (riskView) {
      case RiskView.danger:
        statusColor = const Color(0xFFE53935);
        statusLabel = ar ? 'مرتفعة جداً' : 'Very High';
        description = ar
            ? 'احتمالية نوبة وشيكة، يرجى الاستلقاء وطلب المساعدة'
            : 'Imminent seizure risk detected, please sit or lie down';
        break;
      case RiskView.caution:
        statusColor = const Color(0xFFFF9800);
        statusLabel = ar ? 'متوسطة' : 'Moderate';
        description = ar
            ? (leadTimeMin != null && leadTimeMin! > 0
                  ? 'نشاط عصبي غير معتاد خلال ~${leadTimeMin!.round()} دقيقة'
                  : 'رصد تذبذب عصبي، ننصح بالراحة والاسترخاء')
            : 'Unusual neural fluctuations detected, please relax';
        break;
      case RiskView.safe:
      case RiskView.unknown:
        statusColor = const Color(0xFF009688);
        statusLabel = ar ? 'منخفضة' : 'Low';
        description = ar
            ? 'لم يتم اكتشاف أي نشاط\nغير طبيعي حاليًا'
            : 'No abnormal activity\ndetected currently';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.04),
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
              const ToneIcon(
                icon: Icons.stacked_bar_chart_rounded,
                tone: AccentTone.blue,
                size: 18,
                padding: 5,
                radius: 8,
              ),
              const SizedBox(width: 8),
              Text(
                ar ? 'احتمالية حدوث نوبة' : 'Seizure Probability',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              SizedBox(
                width: 78,
                height: 78,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(78, 78),
                      painter: DonutGaugePainter(
                        progress: rawProb,
                        activeColor: statusColor,
                        strokeWidth: 8,
                      ),
                    ),
                    Text(
                      '$percent%',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: statusColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PastelQuickActionsRow extends StatelessWidget {
  const _PastelQuickActionsRow({
    required this.onAddRecord,
    required this.onEmergencyPlan,
    required this.onTriggers,
    required this.onMore,
  });

  final VoidCallback onAddRecord;
  final VoidCallback onEmergencyPlan;
  final VoidCallback onTriggers;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _PastelTile(
            label: ar ? 'إضافة سجل' : 'Add record',
            icon: Icons.add_circle_outline_rounded,
            tone: AccentTone.blue,
            onTap: onAddRecord,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _PastelTile(
            label: ar ? 'خطة الطوارئ' : 'Emergency plan',
            icon: Icons.emergency_outlined,
            tone: AccentTone.red,
            onTap: onEmergencyPlan,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _PastelTile(
            label: ar ? 'المحفزات' : 'Triggers',
            icon: Icons.bolt_outlined,
            tone: AccentTone.orange,
            onTap: onTriggers,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _PastelTile(
            label: ar ? 'المزيد' : 'More',
            icon: Icons.more_horiz_rounded,
            tone: AccentTone.slate,
            onTap: onMore,
          ),
        ),
      ],
    );
  }
}

class _PastelTile extends StatelessWidget {
  const _PastelTile({
    required this.label,
    required this.icon,
    required this.tone,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final AccentTone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.accent(context, tone);
    // InkWell (not GestureDetector): visible press feedback, and announced
    // as a button with its label by screen readers.
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Column(
          children: [
            Container(
              height: 64,
              decoration: BoxDecoration(
                color: c.container,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Center(child: Icon(icon, color: c.foreground, size: 28)),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentActivitiesSection extends StatelessWidget {
  const _RecentActivitiesSection({
    required this.latestAlert,
    required this.lastObservedAt,
    required this.onViewAll,
  });

  final AlertItem? latestAlert;
  final DateTime? lastObservedAt;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final hasAlert = latestAlert != null;

    final String title;
    final String timeLabel;
    final IconData icon;
    final Color iconColor;
    final Color iconBg;

    if (hasAlert) {
      title = latestAlert!.message;
      timeLabel = TimeAgo.clock(
        latestAlert!.timestamp,
        AppLocalizations.of(context),
      );
      icon = Icons.warning_amber_rounded;
      final c = AppColors.accent(context, AccentTone.orange);
      iconColor = c.foreground;
      iconBg = c.container;
    } else if (lastObservedAt != null) {
      // A reading arrived; no alert is not a clinical «normal» verdict.
      title = ar ? 'وصلت قراءة، لا تنبيه' : 'Reading received, no alert';
      timeLabel = ar
          ? 'اليوم ${TimeAgo.clock(lastObservedAt!, AppLocalizations.of(context))}'
          : 'Today ${TimeAgo.clock(lastObservedAt!, AppLocalizations.of(context))}';
      icon = Icons.check_rounded;
      final c = AppColors.accent(context, AccentTone.green);
      iconColor = c.foreground;
      iconBg = c.container;
    } else {
      title = ar ? 'لا توجد قراءات بعد' : 'No readings yet';
      timeLabel = '—';
      icon = Icons.hourglass_empty_rounded;
      final c = AppColors.accent(context, AccentTone.slate);
      iconColor = c.foreground;
      iconBg = c.container;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              ar ? 'آخر النشاطات' : 'Recent Activities',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            IconButton(
              icon: Icon(
                ar ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 22,
              ),
              onPressed: onViewAll,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.03),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconBg,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      timeLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class DonutGaugePainter extends CustomPainter {
  const DonutGaugePainter({
    required this.progress,
    required this.activeColor,
    this.backgroundColor = const Color(0xFFE8EEF5),
    this.strokeWidth = 9.0,
  });

  final double progress;
  final Color activeColor;
  final Color backgroundColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    final bgPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bgPaint);

    if (progress > 0) {
      final activePaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      final sweepAngle = 2 * math.pi * progress.clamp(0.0, 1.0);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        sweepAngle,
        false,
        activePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant DonutGaugePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.strokeWidth != strokeWidth;
}

class BrainEegPainter extends CustomPainter {
  const BrainEegPainter({required this.isArabic});
  final bool isArabic;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Glowing background radial spot
    final glowPaint = Paint()
      ..shader =
          RadialGradient(
            colors: [
              const Color(0xFF00E5FF).withValues(alpha: 0.35),
              const Color(0xFF0052CC).withValues(alpha: 0.0),
            ],
          ).createShader(
            Rect.fromCircle(
              center: Offset(w * 0.55, h * 0.45),
              radius: w * 0.5,
            ),
          );
    canvas.drawCircle(Offset(w * 0.55, h * 0.45), w * 0.5, glowPaint);

    // Head profile & brain contours
    final headPaint = Paint()
      ..color = const Color(0xFF80D8FF).withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    final path = Path();
    path.moveTo(w * 0.2, h * 0.95);
    path.cubicTo(w * 0.22, h * 0.8, w * 0.18, h * 0.65, w * 0.28, h * 0.4);
    path.cubicTo(w * 0.35, h * 0.15, w * 0.65, h * 0.1, w * 0.8, h * 0.25);
    path.cubicTo(w * 0.95, h * 0.4, w * 0.9, h * 0.7, w * 0.82, h * 0.85);
    path.lineTo(w * 0.82, h * 0.95);
    canvas.drawPath(path, headPaint);

    // Brain sulci / lobes
    final brainPath = Path();
    brainPath.moveTo(w * 0.38, h * 0.35);
    brainPath.cubicTo(
      w * 0.45,
      h * 0.25,
      w * 0.65,
      h * 0.25,
      w * 0.75,
      h * 0.38,
    );
    brainPath.cubicTo(
      w * 0.68,
      h * 0.48,
      w * 0.55,
      h * 0.45,
      w * 0.48,
      h * 0.55,
    );
    brainPath.cubicTo(
      w * 0.42,
      h * 0.62,
      w * 0.55,
      h * 0.68,
      w * 0.68,
      h * 0.62,
    );

    final brainPaint = Paint()
      ..color = const Color(0xFFB3E5FC).withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    canvas.drawPath(brainPath, brainPaint);

    // Active red/amber focus spot (neural activity)
    final focusGlow = Paint()
      ..shader =
          RadialGradient(
            colors: [
              const Color(0xFFFF5252).withValues(alpha: 0.9),
              const Color(0xFFFF9100).withValues(alpha: 0.5),
              Colors.transparent,
            ],
          ).createShader(
            Rect.fromCircle(center: Offset(w * 0.68, h * 0.38), radius: 18),
          );
    canvas.drawCircle(Offset(w * 0.68, h * 0.38), 18, focusGlow);

    final focusCenter = Paint()..color = const Color(0xFFFFF9C4);
    canvas.drawCircle(Offset(w * 0.68, h * 0.38), 3, focusCenter);

    // Flowing EEG trace line across bottom
    final eegPath = Path();
    eegPath.moveTo(0, h * 0.78);
    eegPath.lineTo(w * 0.15, h * 0.78);
    eegPath.lineTo(w * 0.22, h * 0.72);
    eegPath.lineTo(w * 0.28, h * 0.84);
    eegPath.lineTo(w * 0.34, h * 0.68);
    eegPath.lineTo(w * 0.40, h * 0.88);
    eegPath.lineTo(w * 0.46, h * 0.78);
    eegPath.lineTo(w * 0.65, h * 0.78);
    eegPath.lineTo(w * 0.70, h * 0.74);
    eegPath.lineTo(w * 0.75, h * 0.82);
    eegPath.lineTo(w * 0.82, h * 0.78);
    eegPath.lineTo(w, h * 0.78);

    final eegPaint = Paint()
      ..color = const Color(0xFF80D8FF).withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(eegPath, eegPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
                        TimeAgo.formatHhmm12h(e.time, isArabic: l.isArabic),
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
    final lastSeen = DateTime.tryParse(monitoring.lastDeviceSeen ?? '');

    final (RiskView view, String status) = !monitoring.running
        ? (
            RiskView.unknown,
            l.isArabic ? 'المراقبة متوقفة' : 'Monitoring stopped',
          )
        : monitoring.source == SignalSource.simulator
        ? (
            RiskView.safe,
            l.isArabic
                ? 'المراقبة نشطة (محاكاة)'
                : 'Monitoring Active (Simulation)',
          )
        : monitoring.source == SignalSource.dataset
        ? (
            RiskView.safe,
            // Recorded data is replayed, not a live clinical stream.
            l.isArabic
                ? 'المراقبة نشطة (بيانات مسجّلة)'
                : 'Monitoring active (recorded data)',
          )
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
class _MonitoringEngineCard extends StatelessWidget {
  const _MonitoringEngineCard({required this.app});

  final AppState app;

  static String _engineLabel(String? engine, AppLocalizations l) =>
      switch (engine) {
        'cnn_lstm_fusion' => l.engineDeep,
        'sklearn' => l.engineSklearn,
        null => l.engineDeep,
        _ => l.engineRules,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ar = l.isArabic;

    final engineView = app.monitoring.hasUsableAssessment
        ? RiskView.safe
        : RiskView.unknown;
    return SectionCard(
      title: ar
          ? 'محرك الذكاء الاصطناعي والمراقبة السريرية'
          : 'AI Engine & Clinical Monitoring',
      icon: Icons.psychology_outlined,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.of(context, engineView).container,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(
          app.monitoring.hasUsableAssessment
              ? (ar ? 'تقييم حديث متاح' : 'Recent assessment')
              : (ar ? 'لا يوجد تقييم حديث' : 'No recent assessment'),
          style: TextStyle(
            color: AppColors.of(context, engineView).foreground,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledValue(
            label: l.engineLabel,
            value: _engineLabel(app.activeEngine, l),
            icon: Icons.memory,
          ),
          LabeledValue(
            label: ar ? 'مصدر الإشارات المعتمد' : 'Signal Source',
            value: ar ? 'تشغيل بيانات EEG مسجلة' : 'Recorded EEG playback',
            icon: Icons.analytics_outlined,
          ),
          LabeledValue(
            label: ar ? 'معدل التردد الحسابي' : 'Sampling Rate',
            value: app.monitoring.signalSampleRate == null
                ? l.notSet
                : '${app.monitoring.signalSampleRate} Hz',
            icon: Icons.speed,
          ),
          if (!app.apiOnline) ...[
            Gap.vSm,
            InfoNote(
              text: ar
                  ? 'الخادم غير متصل؛ يعتمد العرض على البيانات المحفوظة المتاحة. راجع مصدر الإشارة وحدود المراقبة.'
                  : 'Server offline; playback depends on retained data. Check the signal source and monitoring limitations.',
              icon: Icons.cloud_off_outlined,
              view: RiskView.caution,
            ),
          ],
          Gap.vMd,
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.md),
              ),
            ),
            onPressed: () async {
              await app.forceHighRiskDemo();
              if (context.mounted) {
                AppSnack.warn(
                  context,
                  ar
                      ? '⚡ تم تفعيل سيناريو رصد نوبة: تم رفع درجة الخطر وتفعيل التنبيه والموقع للمرافقين.'
                      : '⚡ Seizure scenario triggered: Alert raised and location dispatched to caregivers.',
                );
              }
            },
            icon: const Icon(Icons.bolt, size: 20),
            label: Text(
              ar
                  ? '⚡ تجربة رصد نوبة مبكرة (اختبار التنبيه والطوارئ)'
                  : '⚡ Trigger Seizure Test Scenario',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Gap.vXs,
          TextButton.icon(
            onPressed: () =>
                Navigator.pushNamed(context, Routes.patientSimulator),
            icon: const Icon(Icons.tune, size: 18),
            label: Text(
              ar
                  ? 'فتح لوحة المحاكي المتقدمة وتجربة النوبات'
                  : 'Open Advanced Simulator Panel',
            ),
          ),
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
            mode: app.operatingMode,
            onSyncNow: app.syncNow,
            pendingCount: app.care.pendingCount,
          ),
          Expanded(
            child: AlertsList(
              alerts: app.monitoring.alerts,
              onAcknowledge: app.acknowledgeAlert,
              onOpen: (a) => Navigator.pushNamed(
                context,
                Routes.alert,
                arguments: AlertRouteArgs(
                  alertId: a.id,
                  patientId: a.patientId,
                ),
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

    // 1. Check if device GPS / location services are turned on
    final serviceEnabled = await app.location.isServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return;
      setState(() => _sharing = false);
      await _showEnableGpsDialog(app);
      return;
    }

    // 2. Explicitly verify / request location permission
    var permission = await app.location.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await app.location.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      if (!mounted) return;
      setState(() => _sharing = false);
      await _showPermissionSettingsDialog(app);
      return;
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      if (!mounted) return;
      setState(() => _sharing = false);
      AppSnack.error(
        context,
        'لم يتم منح إذن تحديد الموقع. يلزم منح الصلاحية لمشاركة موقعك مع عائلتك.',
      );
      return;
    }

    // 3. Check for approximate permission on Android 12+
    try {
      final accStatus = await Geolocator.getLocationAccuracy();
      if (accStatus == LocationAccuracyStatus.reduced) {
        if (mounted) {
          AppSnack.warn(
            context,
            'تنبيه: تم منح إذن «الموقع التقريبي» فقط. للحصول على موقع دقيق عبر الأقمار الصناعية (GPS)، يُفضل منح «الموقع الدقيق» في إعدادات التطبيق.',
          );
        }
      }
    } catch (_) {}

    // 4. Acquire GPS fix and publish to family
    final ok = await app.shareMyLocationWithFamily();
    if (!mounted) return;
    setState(() => _sharing = false);

    if (ok) {
      final fix = app.location.lastResult?.fix;
      if (fix != null && fix.isCoarse) {
        AppSnack.warn(
          context,
          'تم إرسال الموقع بدقة تقريبية (±${(fix.accuracy! / 1000).toStringAsFixed(1)} كم). يرجى التواجد في مكان مكشوف لتحديث الـ GPS بالأقمار الصناعية.',
        );
      } else {
        AppSnack.success(
          context,
          'تم إرسال وتحديث موقعك الجغرافي لأفراد أسرتك بنجاح.',
        );
      }
    } else {
      final status = app.location.lastResult?.status;
      if (status == LocationStatus.serviceDisabled) {
        await _showEnableGpsDialog(app);
      } else if (status == LocationStatus.permissionDeniedForever) {
        await _showPermissionSettingsDialog(app);
      } else if (status == LocationStatus.timedOut) {
        AppSnack.warn(
          context,
          'استغرق استقبال إشارة الأقمار الصناعية (GPS) وقتاً أطول من المتوقع. يرجى المحاولة في مكان مفتوح.',
        );
      } else if (status == LocationStatus.unsupported) {
        AppSnack.error(
          context,
          'جهازك أو النظام الحالي لا يدعم مستشعر الموقع الجغرافي (GPS).',
        );
      } else {
        AppSnack.error(
          context,
          'تعذّر التقاط إحداثيات الموقع بدقة. تأكد من تفعيل الـ GPS والمحاولة مجدداً.',
        );
      }
    }
  }

  Future<void> _showEnableGpsDialog(AppState app) async {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.location_off, color: Colors.amber, size: 36),
        title: Text(
          ar ? 'خدمة تحديد الموقع (GPS) مغلقة' : 'Location Service Disabled',
          textAlign: TextAlign.center,
        ),
        content: Text(
          ar
              ? 'خدمة الـ GPS مغلقة في هاتفك. يرجى تفعيل الموقع لتتمكن من إرسال وتحديث موقعك لعائلتك في حالات السلامة والطوارئ.'
              : 'GPS is disabled on your device. Please enable location services to share your position with your family.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.location_on, size: 18),
            label: Text(ar ? 'تشغيل الـ GPS' : 'Enable GPS'),
          ),
        ],
      ),
    );
    if (proceed == true && mounted) {
      await app.location.openLocationSettings();
    }
  }

  Future<void> _showPermissionSettingsDialog(AppState app) async {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.security, color: Colors.redAccent, size: 36),
        title: Text(
          ar
              ? 'إذن الموقع معطل في إعدادات الهاتف'
              : 'Location Permission Denied in Settings',
          textAlign: TextAlign.center,
        ),
        content: Text(
          ar
              ? 'تم رفض إذن الموقع للتطبيق سابقاً في النظام. يتطلب تفعيله فتح إعدادات التطبيق ومنح إذن «الموقع الجغرافي» لتتمكن عائلتك من متابعة مكانك ونجدتك فوراً.'
              : 'Location permission is denied permanently. Please open App Settings and grant location access to allow family monitoring.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.settings, size: 18),
            label: Text(ar ? 'فتح إعدادات التطبيق' : 'Open Settings'),
          ),
        ],
      ),
    );
    if (proceed == true && mounted) {
      await app.location.openAppSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final app = context.watch<AppState>();
    final lastLoc = app.messages.lastSharedLocation;

    return Container(
      padding: Insets.card,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: Radii.rMd,
        border: Border.all(
          color: Colors.teal.withValues(alpha: isDark ? 0.7 : 0.5),
          width: 1.5,
        ),
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
                  color: Colors.teal.withValues(alpha: isDark ? 0.22 : 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.location_on,
                  color: Colors.teal,
                  size: 22,
                ),
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
                color: Colors.teal.withValues(alpha: isDark ? 0.16 : 0.06),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, size: 14, color: Colors.teal),
                  Gap.hXs,
                  Expanded(
                    child: Text(
                      'آخر موقع مسجل: ${(lastLoc['latitude'] as num).toStringAsFixed(4)}, ${(lastLoc['longitude'] as num).toStringAsFixed(4)}${lastLoc['accuracy'] != null ? ' (دقة: ±${(lastLoc['accuracy'] as num) > 1000 ? '${((lastLoc['accuracy'] as num) / 1000).toStringAsFixed(1)} كم' : '${(lastLoc['accuracy'] as num).round()} م'})' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.teal.shade200
                            : Colors.teal.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (lastLoc['accuracy'] != null &&
                (lastLoc['accuracy'] as num) > 1000) ...[
              Gap.vXs,
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.amber.shade900.withValues(alpha: 0.25)
                      : Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(
                    color: isDark
                        ? Colors.amber.shade700
                        : Colors.amber.shade300,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: isDark
                          ? Colors.amber.shade300
                          : Colors.amber.shade900,
                    ),
                    Gap.hXs,
                    Expanded(
                      child: Text(
                        'تنبيه: تم رصد الموقع بدقة تقريبية عبر شبكة الإنترنت وليس عبر الأقمار الصناعية (GPS) مباشرة. للحصول على إحداثيات دقيقة وتفادي الخطأ، يرجى تفعيل الموقع الدقيق والاقتراب من نافذة أو مكان مكشوف.',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: isDark
                              ? Colors.amber.shade200
                              : Colors.amber.shade900,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            Gap.vSm,
          ],
          SizedBox(
            width: double.infinity,
            height: A11y.minTouchTarget,
            child: FilledButton.icon(
              // Theme «safe» tone (white on Colors.teal was 3.7:1).
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.of(context, RiskView.safe).solid,
                foregroundColor: AppColors.of(context, RiskView.safe).onSolid,
              ),
              onPressed: _sharing ? null : () => _share(app),
              icon: _sharing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.of(context, RiskView.safe).onSolid,
                      ),
                    )
                  : const Icon(Icons.my_location),
              label: Text(
                _sharing
                    ? 'جارٍ تحديد وإرسال الموقع...'
                    : 'إرسال وتحديث موقعي للأسرة الآن',
              ),
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
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.monitor_heart,
                color: theme.colorScheme.onPrimary,
                size: 22,
              ),
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
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: 14,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}

class PatientMonitoringScreen extends StatefulWidget {
  const PatientMonitoringScreen({super.key});
  @override
  State<PatientMonitoringScreen> createState() =>
      _PatientMonitoringScreenState();
}

class _PatientMonitoringScreenState extends State<PatientMonitoringScreen> {
  bool _busy = false;
  Future<void> _toggle(AppState app) async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    if (app.monitoring.running) {
      final stop = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(
            l.isArabic ? 'إيقاف المراقبة المحلية؟' : 'Stop local monitoring?',
          ),
          content: Text(
            l.isArabic
                ? 'لن يجمع هذا التطبيق تقييمات جديدة حتى تعيد تشغيل المراقبة. لا يوقف ذلك جهازًا أو خادمًا مستقلًا.'
                : 'This app will not collect new assessments until you restart monitoring. An independent device or server is not stopped.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(l.isArabic ? 'إيقاف' : 'Stop'),
            ),
          ],
        ),
      );
      if (stop != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      await app.setMonitoringEnabled(!app.monitoring.running);
    } catch (_) {
      if (mounted) AppSnack.error(context, l.errUnknown);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l = AppLocalizations.of(context);
    final prediction = app.monitoring.latestPrediction;
    final ar = l.isArabic;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(
          l.isArabic ? 'المراقبة المباشرة' : 'Live Monitoring',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        actions: [
          IconButton(
            tooltip: l.tabDevice,
            onPressed: () => Navigator.pushNamed(context, Routes.patientDevice),
            icon: const Icon(
              Icons.settings_input_component_outlined,
              color: Color(0xFF1976D2),
            ),
          ),
        ],
      ),
      body: ResponsiveContent(
        maxWidth: 960,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          children: [
            // Live Status Header Banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  colors: app.monitoring.running
                      ? [const Color(0xFF003B94), const Color(0xFF0070F3)]
                      : [const Color(0xFF455A64), const Color(0xFF607D8B)],
                ),
                boxShadow: [
                  BoxShadow(
                    color:
                        (app.monitoring.running
                                ? const Color(0xFF0070F3)
                                : Colors.black)
                            .withValues(alpha: 0.2),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: app.monitoring.running
                          ? const Color(0xFF00E676)
                          : Colors.amber,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color:
                              (app.monitoring.running
                                      ? const Color(0xFF00E676)
                                      : Colors.amber)
                                  .withValues(alpha: 0.8),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      app.monitoring.running
                          ? (ar
                                ? 'المراقبة اللحظية جارية ومستمرة'
                                : 'Live Monitoring Active')
                          : (ar
                                ? 'المراقبة متوقفة محلياً'
                                : 'Local Monitoring Paused'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Gap.vMd,
            MonitoringCapabilityNotice(app: app),
            Gap.vMd,
            RiskGauge(
              view: app.riskView,
              freshnessLabel:
                  '${l.lastUpdate}: ${TimeAgo.since(app.lastObservedAt, l)}',
              reasonLabel: l.riskUnknownWhy,
            ),
            Gap.vMd,
            _SignalSection(reading: app.monitoring.latestReading),
            Gap.vMd,
            _DeviceSection(monitoring: app.monitoring),
            Gap.vMd,
            if (prediction != null) ...[
              PredictionGauge(prediction: prediction),
              Gap.vMd,
              LeadTimeCard(
                prediction: prediction,
                engine:
                    app.monitoring.latestAssessment?.features['engine']
                        as String?,
              ),
              Gap.vMd,
            ],
            _MonitoringEngineCard(app: app),
            Gap.vLg,
            SizedBox(
              height: A11y.minTouchTarget,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: app.monitoring.running
                      ? AppColors.of(context, RiskView.danger).solid
                      : Theme.of(context).colorScheme.primary,
                  foregroundColor: app.monitoring.running
                      ? AppColors.of(context, RiskView.danger).onSolid
                      : Theme.of(context).colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: _busy ? null : () => _toggle(app),
                icon: Icon(
                  app.monitoring.running
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                ),
                label: Text(
                  app.monitoring.running
                      ? (ar
                            ? 'إيقاف المراقبة المحلية'
                            : 'Stop Local Monitoring')
                      : (ar ? 'بدء المراقبة الآن' : 'Start Monitoring Now'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            Gap.vLg,
          ],
        ),
      ),
    );
  }
}
