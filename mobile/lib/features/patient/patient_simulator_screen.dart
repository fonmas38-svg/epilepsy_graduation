import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/common.dart';
import '../../core/ui/risk_indicator.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import '../../services/eeg_hardware_device.dart';
import '../../widgets/app_drawer.dart';

/// Flagship Real-time Vital Telemetry Simulator & Interactive Alert Escalation Screen.
class PatientSimulatorScreen extends StatefulWidget {
  const PatientSimulatorScreen({super.key});

  @override
  State<PatientSimulatorScreen> createState() => _PatientSimulatorScreenState();
}

class _PatientSimulatorScreenState extends State<PatientSimulatorScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;
  late final AnimationController _waveController;
  int _currentCyclePhaseIndex = -1;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    _pulseScale = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    // Disable automatic pre-alerts while the user is on this screen.
    // The user has full manual control here; automatic alerts would be annoying.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().monitoring.disableAutoAlerts();
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _waveController.dispose();
    // Re-enable automatic alerts when the user leaves the simulator screen.
    // Use a post-frame callback because dispose() is called after the widget
    // is removed from the tree but the context may still be accessible.
    try {
      context.read<AppState>().monitoring.enableAutoAlerts();
    } catch (_) {}
    super.dispose();
  }

  void _adjustPulseSpeed(double hr) {
    if (hr <= 0) return;
    final beatsPerSec = hr / 60.0;
    final ms = (1000 / beatsPerSec).clamp(300, 1200).toInt();
    _pulseController.duration = Duration(milliseconds: ms ~/ 2);
    // Speed up wave sweep proportionally when heart rate rises (simulating tachycardia)
    final waveSec = hr > 115 ? 1.5 : (hr > 90 ? 2.2 : 3.0);
    _waveController.duration = Duration(milliseconds: (waveSec * 1000).toInt());
  }

  Future<void> _escalate(AppState app, RiskLabel level) async {
    await app.monitoring.tick(forcePattern: level);
    if (!mounted) return;
    final msg = switch (level) {
      RiskLabel.stable => 'تم ضبط الحالة: مستقر / طبيعي (إشارات هادئة)',
      RiskLabel.watch => 'تم رفع الحالة: تنبيه خفيف / متابعة نشاط الدماغ',
      RiskLabel.highRisk => 'تم تصعيد الحالة: إنذار حرج وتحديد الموقع للمرافقين',
    };
    AppSnack.success(context, msg);
  }

  /// Run a complete seizure cycle automatically using clinical EEG dataset & CNN-LSTM model:
  /// Interictal → Pre-Ictal (with forecast & countdown) → Ictal (with alert & location) → Post-Ictal (recovery)
  bool _cycleRunning = false;
  Future<void> _runFullCycle(AppState app) async {
    if (_cycleRunning) return;
    setState(() {
      _cycleRunning = true;
      _currentCyclePhaseIndex = 0;
    });

    app.monitoring.enableAutoAlerts();

    final phases = [
      (
        SeizurePhase.interictal,
        RiskLabel.stable,
        '1. مرحلة بين النوبات (Interictal) — إشارات طبيعية وهدوء سريري',
        const Duration(seconds: 4),
      ),
      (
        SeizurePhase.preIctal,
        RiskLabel.watch,
        '2. مرحلة ما قبل النوبة (Pre-Ictal) — توقع حدوث نوبة بالذكاء الاصطناعي وبدء الإنذار المبكر',
        const Duration(seconds: 5),
      ),
      (
        SeizurePhase.ictal,
        RiskLabel.highRisk,
        '3. مرحلة النوبة النشطة (Ictal) — شحنات صرعية حادة وتصعيد فوري وإرسال الموقع',
        const Duration(seconds: 6),
      ),
      (
        SeizurePhase.postIctal,
        RiskLabel.stable,
        '4. مرحلة ما بعد النوبة (Post-Ictal) — هدوء الشحنات وتعافي المريض التلقائي',
        const Duration(seconds: 4),
      ),
    ];

    for (var i = 0; i < phases.length; i++) {
      if (!mounted) break;
      setState(() => _currentCyclePhaseIndex = i);
      final (phase, label, msg, duration) = phases[i];
      app.monitoring.cycleController.forcePhase(phase);

      if (phase == SeizurePhase.preIctal) {
        await app.simulatePreIctalForecast();
      } else {
        await app.monitoring.tick(forcePattern: label);
      }

      if (mounted) AppSnack.info(context, msg);
      await Future<void>.delayed(duration);
    }

    if (mounted) {
      app.monitoring.disableAutoAlerts();
      setState(() {
        _cycleRunning = false;
        _currentCyclePhaseIndex = -1;
      });
      AppSnack.success(context, 'اكتملت محاكاة دورة النوبة السريرية بالكامل ✓');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final reading = app.monitoring.latestReading;
    final assessment = app.monitoring.latestAssessment;
    final prediction = app.monitoring.latestPrediction;
    final hr = reading?.hr ?? 72.0;
    _adjustPulseSpeed(hr);

    final riskTone = AppColors.of(context, app.riskView);

    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('محاكي الإشارات الحيوية والتصعيد'),
        actions: [
          IconButton(
            tooltip: 'تحديث القياسات',
            onPressed: () => app.monitoring.tick(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: Insets.pageBottomSafe,
        children: [
          // 0. Live Pre-Alert Countdown Banner if active
          if (app.preAlert != null) ...[
            Container(
              padding: Insets.card,
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: Radii.rMd,
                border: Border.all(color: Colors.amber.shade600, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.amber.withValues(alpha: 0.15),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.amber.shade700,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${app.preAlertSecondsLeft}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 22,
                      ),
                    ),
                  ),
                  Gap.hMd,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'إنذار ما قبل النوبة نشط (Pre-Ictal)',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        Gap.vXs,
                        Text(
                          'سيتم التصعيد التلقائي للأسرة والطبيب خلال ${app.preAlertSecondsLeft} ثانية إذا لم يتم الإلغاء',
                          style: theme.textTheme.bodySmall?.copyWith(color: Colors.amber.shade900),
                        ),
                      ],
                    ),
                  ),
                  Gap.hSm,
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(backgroundColor: Colors.amber.shade200),
                    onPressed: () => app.cancelPreAlert(),
                    child: const Text('إلغاء التنبيه'),
                  ),
                ],
              ),
            ),
            Gap.vMd,
          ],

          // 1. Live Patient Status Header Card
          Container(
            padding: Insets.card,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [riskTone.container, theme.colorScheme.surface],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
              borderRadius: Radii.rMd,
              border: Border.all(color: riskTone.solid.withValues(alpha: 0.5), width: 1.5),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(Gap.sm),
                          decoration: BoxDecoration(
                            color: riskTone.solid,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.sensors, color: riskTone.onSolid, size: 20),
                        ),
                        Gap.hSm,
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'الحالة الفسيولوجية الحالية',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              RiskCopy.title(app.riskView, l),
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: riskTone.foreground,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(Radii.pill),
                        border: Border.all(color: theme.colorScheme.outlineVariant),
                      ),
                      child: Text(
                        'ثقة النموذج: ${((assessment?.confidence ?? 0.95) * 100).toInt()}%',
                        style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                if (prediction != null && prediction.predicted) ...[
                  const Divider(height: Gap.lg),
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: riskTone.solid, size: 20),
                      Gap.hSm,
                      Expanded(
                        child: Text(
                          'توقع اقتراب نوبة محتملة خلال ${prediction.leadTimeMin?.round() ?? 15} دقيقة',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: riskTone.foreground,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Gap.vMd,

          // 2. Cardiac Telemetry (Heart Rate & ECG)
          _TelemetryCard(
            title: 'نبض القلب والنشاط القلبي (ECG)',
            icon: Icons.favorite,
            accentColor: Colors.redAccent,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        ScaleTransition(
                          scale: _pulseScale,
                          child: const Icon(Icons.favorite, color: Colors.redAccent, size: 36),
                        ),
                        Gap.hMd,
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RichText(
                              text: TextSpan(
                                text: '${hr.toInt()} ',
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurface,
                                ),
                                children: [
                                  TextSpan(
                                    text: 'BPM (نبضة/دقيقة)',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              hr > 120
                                  ? 'تسارع قلبي حاد (مصاحب للنوبة)'
                                  : hr > 90
                                      ? 'معدل متزايد (نشاط تنبيهي)'
                                      : 'إيقاع جيبي طبيعي (منتظم)',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: hr > 100 ? Colors.redAccent : Colors.green,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
                Gap.vSm,
                // Live moving ECG waveform graph
                AnimatedBuilder(
                  animation: _waveController,
                  builder: (context, _) => _LiveOscilloscopeWave(
                    data: reading?.ecg ?? const [],
                    lineColor: Colors.redAccent,
                    progress: _waveController.value,
                    height: 75,
                    label: 'ECG LEAD II (mV)',
                  ),
                ),
              ],
            ),
          ),
          Gap.vMd,

          // 3. Neurological Telemetry (EEG Brain Waves)
          _TelemetryCard(
            title: 'النشاط الكهربائي للدماغ (EEG Brain Waves)',
            icon: Icons.psychology_outlined,
            accentColor: Colors.blueAccent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Live moving EEG waveform graph
                AnimatedBuilder(
                  animation: _waveController,
                  builder: (context, _) => _LiveOscilloscopeWave(
                    data: reading?.eeg ?? const [],
                    lineColor: const Color(0xFF00E5FF),
                    progress: _waveController.value,
                    height: 95,
                    label: 'EEG FP1-F3 (µV)',
                  ),
                ),
                Gap.vSm,
                // Brain wave breakdown chips
                Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.xs,
                  children: [
                    _FrequencyBadge(
                      label: 'Alpha (8-13 Hz)',
                      active: hr < 90,
                      color: Colors.green,
                    ),
                    _FrequencyBadge(
                      label: 'Beta (13-30 Hz)',
                      active: hr >= 90 && hr <= 110,
                      color: Colors.amber,
                    ),
                    _FrequencyBadge(
                      label: 'Theta (4-8 Hz)',
                      active: hr >= 85,
                      color: Colors.blue,
                    ),
                    _FrequencyBadge(
                      label: 'Spikes (شحنات صرعية)',
                      active: hr > 115,
                      color: Colors.redAccent,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Gap.vMd,

          // 4. Motion & Tremor Telemetry
          _TelemetryCard(
            title: 'مستشعر الحركة والتشنج العضلي (Motion & Tremors)',
            icon: Icons.directions_run_outlined,
            accentColor: Colors.teal,
            child: Column(
              children: [
                // Live moving Motion waveform graph
                AnimatedBuilder(
                  animation: _waveController,
                  builder: (context, _) => _LiveOscilloscopeWave(
                    data: reading?.motion ?? const [],
                    lineColor: const Color(0xFF00E676),
                    progress: _waveController.value,
                    height: 60,
                    label: 'ACCELEROMETER (g)',
                  ),
                ),
                Gap.vXs,
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    reading != null && reading.motion.isNotEmpty && reading.motion.any((m) => m.abs() > 0.8)
                        ? '⚠️ رصد اهتزازات وتشنجات حركية شديدة'
                        : 'الحركة ضمن الحدود الطبيعية المستقرة',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: reading != null && reading.motion.any((m) => m.abs() > 0.8)
                          ? Colors.deepOrange
                          : Colors.teal,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Gap.vLg,

          // 5. Interactive Multi-Tier Escalation Panel
          Text(
            'لوحة التحكم وتصعيد حالة المريض',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          Gap.vXs,
          Text(
            'حدد درجة خطورة الحالة لمحاكاة الاستجابة وتوليد التنبيهات اللازمة فوراً:',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          Gap.vMd,

          // Tier 1: Stable
          _EscalateButton(
            title: 'المستوى 1: مستقر / طبيعي (Stable Baseline)',
            subtitle: 'نبض 70-75 BPM، إشارات دماغ هادئة (ألفا)، لا توجد تنبيهات',
            color: Colors.green,
            icon: Icons.check_circle_outline,
            onPressed: () => _escalate(app, RiskLabel.stable),
          ),
          Gap.vSm,

          // Tier 2: Watch / Mild Alert
          _EscalateButton(
            title: 'المستوى 2: تنبيه خفيف / مراقبة (Watch / Mild)',
            subtitle: 'نبض 90-95 BPM، نشاط إشارات غير معتاد للمتابعة',
            color: Colors.amber.shade700,
            icon: Icons.visibility_outlined,
            onPressed: () => _escalate(app, RiskLabel.watch),
          ),
          Gap.vSm,

          // Tier 3: Moderate / Pre-Ictal Warning
          _EscalateButton(
            title: 'المستوى 3: إنذار استباقي / ما قبل النوبة (Pre-Ictal)',
            subtitle: 'نبض 110+ BPM، تفريغات استباقية، ونافذة عد تنازلي 30 ثانية حية',
            color: Colors.deepOrange,
            icon: Icons.timer,
            onPressed: () async {
              await app.simulatePreIctalForecast();
              if (context.mounted) {
                AppSnack.warn(context, 'تم تفعيل إنذار ما قبل النوبة وبدء عداد الـ 30 ثانية!');
              }
            },
          ),
          Gap.vSm,

          // Tier 4: Critical / Active Seizure Alert
          _EscalateButton(
            title: 'المستوى 4: إنذار حرج / نوبة صرع نشطة (Critical)',
            subtitle: 'نبض 130+ BPM، تفريغات حادة، تشنجات، إشعار فوري للأسرة والطبيب',
            color: Colors.red.shade700,
            icon: Icons.notification_important,
            isCritical: true,
            onPressed: () => _escalate(app, RiskLabel.highRisk),
          ),
          Gap.vLg,

          // ── Full Seizure Cycle ─────────────────────────────────────────
          const Divider(),
          Gap.vSm,
          _SeizurePhaseIndicator(
            phase: app.monitoring.cycleController.currentPhase,
            activeCycleIndex: _currentCyclePhaseIndex,
          ),
          Gap.vMd,

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _cycleRunning
                    ? theme.colorScheme.surfaceContainerHighest
                    : const Color(0xFF6C3483),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
              ),
              icon: _cycleRunning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.auto_mode_rounded),
              label: Text(
                _cycleRunning
                    ? 'جاري محاكاة الدورة السريرية بالذكاء الاصطناعي...'
                    : 'محاكاة دورة نوبة كاملة (4 مراحل سريرية)',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              onPressed: _cycleRunning ? null : () => _runFullCycle(app),
            ),
          ),
          Gap.vXs,
          Text(
            'بين النوبات ← ما قبل النوبة (إنذار مبكر) ← أثناء النوبة (تحديد الموقع) ← التعافي',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _SeizurePhaseIndicator extends StatelessWidget {
  const _SeizurePhaseIndicator({
    required this.phase,
    this.activeCycleIndex = -1,
  });

  final SeizurePhase phase;
  final int activeCycleIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon, label) = switch (phase) {
      SeizurePhase.interictal => (
        Colors.green,
        Icons.check_circle_outline,
        'المرحلة: بين النوبات (Interictal — إشارات مستقرة)',
      ),
      SeizurePhase.preIctal => (
        Colors.orange,
        Icons.warning_amber_rounded,
        'المرحلة: ما قبل النوبة (Pre-Ictal — تنبؤ الذكاء الاصطناعي)',
      ),
      SeizurePhase.ictal => (
        Colors.red,
        Icons.notification_important,
        'المرحلة: أثناء النوبة (Ictal — شحنات صرعية وتنبيه طوارئ)',
      ),
      SeizurePhase.postIctal => (
        Colors.blue,
        Icons.bedtime_rounded,
        'المرحلة: ما بعد النوبة (Post-Ictal — تعافٍ فسيولوجي)',
      ),
    };

    final stages = [
      ('1. هدوء', Colors.green),
      ('2. ما قبل النوبة', Colors.orange),
      ('3. نوبة نشطة', Colors.red),
      ('4. تعافٍ', Colors.blue),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 22),
              Gap.hMd,
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ],
          ),
          Gap.vSm,
          // 4-Phase Stepper Tracker
          Row(
            children: [
              for (var i = 0; i < stages.length; i++) ...[
                if (i > 0)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: activeCycleIndex >= i
                          ? stages[i].$2
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: activeCycleIndex == i
                        ? stages[i].$2
                        : (activeCycleIndex > i
                            ? stages[i].$2.withValues(alpha: 0.25)
                            : theme.colorScheme.surface),
                    borderRadius: BorderRadius.circular(Radii.pill),
                    border: Border.all(
                      color: activeCycleIndex >= i
                          ? stages[i].$2
                          : theme.colorScheme.outlineVariant,
                      width: activeCycleIndex == i ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    stages[i].$1,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: activeCycleIndex == i
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: activeCycleIndex == i
                          ? Colors.white
                          : (activeCycleIndex > i
                              ? stages[i].$2
                              : theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _TelemetryCard extends StatelessWidget {
  const _TelemetryCard({
    required this.title,
    required this.icon,
    required this.accentColor,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Color accentColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: Insets.card,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: Radii.rMd,
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
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
              Icon(icon, size: 20, color: accentColor),
              Gap.hSm,
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const Divider(height: Gap.md),
          child,
        ],
      ),
    );
  }
}

class _FrequencyBadge extends StatelessWidget {
  const _FrequencyBadge({
    required this.label,
    required this.active,
    required this.color,
  });

  final String label;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.15) : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(
          color: active ? color : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: active ? color : theme.colorScheme.onSurfaceVariant,
          fontWeight: active ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}

class _EscalateButton extends StatelessWidget {
  const _EscalateButton({
    required this.title,
    required this.subtitle,
    required this.color,
    required this.icon,
    required this.onPressed,
    this.isCritical = false,
  });

  final String title;
  final String subtitle;
  final Color color;
  final IconData icon;
  final VoidCallback onPressed;
  final bool isCritical;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isCritical ? 0.12 : 0.06),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: color.withValues(alpha: isCritical ? 0.8 : 0.4), width: isCritical ? 2 : 1),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            Gap.hMd,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  Gap.vXs,
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, size: 14, color: color),
          ],
        ),
      ),
    );
  }
}

class _LiveOscilloscopeWave extends StatelessWidget {
  const _LiveOscilloscopeWave({
    required this.data,
    required this.lineColor,
    required this.progress,
    required this.height,
    this.label,
  });

  final List<double> data;
  final Color lineColor;
  final double progress;
  final double height;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF0D1520), // Clinical dark monitor display
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: lineColor.withValues(alpha: 0.35),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        children: [
          // 1. Grid Background & Moving Oscilloscope Waveform
          Positioned.fill(
            child: CustomPaint(
              painter: _OscilloscopeWavePainter(
                data: data,
                lineColor: lineColor,
                progress: progress,
              ),
            ),
          ),
          // 2. Clinical Monitor Overlay Tag
          if (label != null)
            Positioned(
              top: 5,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  label!,
                  style: TextStyle(
                    color: lineColor.withValues(alpha: 0.85),
                    fontSize: 9.0,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          // 3. Live 256Hz Pill Indicator
          Positioned(
            top: 5,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: lineColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: lineColor,
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  'LIVE 256Hz',
                  style: TextStyle(
                    color: lineColor.withValues(alpha: 0.75),
                    fontSize: 8.5,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
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

class _OscilloscopeWavePainter extends CustomPainter {
  _OscilloscopeWavePainter({
    required this.data,
    required this.lineColor,
    required this.progress,
  });

  final List<double> data;
  final Color lineColor;
  final double progress; // 0.0 to 1.0 (continuous sweep)

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    final midY = height / 2;

    // 1. Draw subtle clinical grid lines (16px spacing)
    final gridPaint = Paint()
      ..color = const Color(0xFF1E2D40).withValues(alpha: 0.45)
      ..strokeWidth = 0.5;

    const gridSize = 16.0;
    for (double x = 0; x < width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, height), gridPaint);
    }
    for (double y = 0; y < height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(width, y), gridPaint);
    }

    // Baseline center axis
    final centerAxisPaint = Paint()
      ..color = lineColor.withValues(alpha: 0.15)
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(0, midY), Offset(width, midY), centerAxisPaint);

    // If data is empty, synthesize a baseline waveform
    final samples = data.isNotEmpty
        ? data
        : List<double>.generate(128, (i) => 0.1 * math.sin(i * 0.1));

    final count = samples.length;
    final sweepX = progress * width;

    // 2. Prepare glowing & solid trace paints
    final glowPaint = Paint()
      ..color = lineColor.withValues(alpha: 0.35)
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final tracePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Sample cyclically based on progress so the waveform fluidly flows horizontally:
    final int offset = (progress * count).floor();
    final path = Path();
    final dx = width / (count - 1);

    double? lastY;
    double? headY;

    for (var i = 0; i < count; i++) {
      final sampleIdx = (i + offset) % count;
      final rawVal = samples[sampleIdx];
      final y = (midY - rawVal * (height * 0.38)).clamp(3.0, height - 3.0);
      final x = i * dx;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      lastY = y;
      if (headY == null && x >= sweepX) {
        headY = y;
      }
    }

    // Draw glow and primary trace
    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, tracePaint);

    // 3. Draw moving oscilloscope scan beam & glowing leading head
    headY ??= lastY ?? midY;

    // Vertical sweeping scan bar (faint vertical beam)
    final scanBarPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          lineColor.withValues(alpha: 0.0),
          lineColor.withValues(alpha: 0.22),
          lineColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(sweepX - 8, 0, 16, height));
    canvas.drawRect(Rect.fromLTWH(sweepX - 8, 0, 16, height), scanBarPaint);

    // Glowing leading head dot
    final dotGlow = Paint()
      ..color = Colors.white
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawCircle(Offset(sweepX, headY), 4.0, dotGlow);

    final dotSolid = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(sweepX, headY), 2.2, dotSolid);
  }

  @override
  bool shouldRepaint(covariant _OscilloscopeWavePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.data != data;
}
