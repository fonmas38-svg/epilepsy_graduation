import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/common.dart';
import '../../core/ui/risk_indicator.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import '../../widgets/app_drawer.dart';

/// Flagship Real-time Vital Telemetry Simulator & Interactive Alert Escalation Screen.
class PatientSimulatorScreen extends StatefulWidget {
  const PatientSimulatorScreen({super.key});

  @override
  State<PatientSimulatorScreen> createState() => _PatientSimulatorScreenState();
}

class _PatientSimulatorScreenState extends State<PatientSimulatorScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;

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
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _adjustPulseSpeed(double hr) {
    if (hr <= 0) return;
    final beatsPerSec = hr / 60.0;
    final ms = (1000 / beatsPerSec).clamp(300, 1200).toInt();
    _pulseController.duration = Duration(milliseconds: ms ~/ 2);
  }

  Future<void> _escalate(AppState app, RiskLabel level) async {
    await app.monitoring.tick(forcePattern: level);
    if (!mounted) return;
    final msg = switch (level) {
      RiskLabel.stable => 'تم ضبط الحالة: مستقر / طبيعي',
      RiskLabel.watch => 'تم رفع الحالة: تنبيه خفيف / مراقبة',
      RiskLabel.highRisk => 'تم تصعيد الحالة: إنذار حرج / خطر مرتفع',
    };
    AppSnack.success(context, msg);
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
                // Waveform graph
                Container(
                  height: 70,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: CustomPaint(
                    painter: _SignalWavePainter(
                      data: reading?.ecg ?? const [],
                      lineColor: Colors.redAccent,
                    ),
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
                Container(
                  height: 90,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: CustomPaint(
                    painter: _SignalWavePainter(
                      data: reading?.eeg ?? const [],
                      lineColor: Colors.blueAccent,
                    ),
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
                Container(
                  height: 50,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: CustomPaint(
                    painter: _SignalWavePainter(
                      data: reading?.motion ?? const [],
                      lineColor: Colors.teal,
                    ),
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

class _SignalWavePainter extends CustomPainter {
  const _SignalWavePainter({
    required this.data,
    required this.lineColor,
  });

  final List<double> data;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    final dx = size.width / (data.length - 1);
    final midY = size.height / 2;

    for (var i = 0; i < data.length; i++) {
      final val = data[i];
      final y = (midY - val * (size.height * 0.35)).clamp(2.0, size.height - 2.0);
      if (i == 0) {
        path.moveTo(0, y);
      } else {
        path.lineTo(i * dx, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SignalWavePainter oldDelegate) => true;
}
