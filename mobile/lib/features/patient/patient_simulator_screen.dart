import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/risk_indicator.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import '../../services/monitoring_service.dart';
import '../../services/simulator/model_evaluation.dart';
import '../../services/simulator/sim_types.dart';
import '../../services/simulator/simulation_scheduler.dart';
import '../../widgets/app_drawer.dart';

/// Virtual-sensor control room: what the sensor is streaming now, demo
/// controls, and how accurately the cloud and phone models are judging it.
///
/// The sensor runs by itself (calm for the chosen period, then a full
/// seizure, and so on). The buttons only change what it streams; whether an
/// alert is raised is always the model's decision.
class PatientSimulatorScreen extends StatefulWidget {
  const PatientSimulatorScreen({super.key});

  @override
  State<PatientSimulatorScreen> createState() => _PatientSimulatorScreenState();
}

class _PatientSimulatorScreenState extends State<PatientSimulatorScreen> {
  SimSeizureType _type = SimSeizureType.tonicClonic;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Countdown refresh.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String _mmss(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _ensureVirtual(AppState app) async {
    if (app.monitoring.source != SignalSource.simulator) {
      await app.useSimulator();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final ar = AppLocalizations.of(context).isArabic;
    final m = app.monitoring;
    final sim = m.simulation;
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: Text(
          ar ? 'الحساس الافتراضي والمحاكاة' : 'Virtual sensor & simulation',
        ),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([sim, m.evaluation]),
        builder: (context, _) {
          final truth = sim.current;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              if (m.source != SignalSource.simulator)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InfoNote(
                    text: ar
                        ? 'مصدر الإشارات الحالي ليس الحساس الافتراضي.'
                        : 'The current signal source is not the virtual sensor.',
                    view: RiskView.caution,
                  ),
                ),
              _StatusCard(sim: sim, truth: truth, ar: ar, mmss: _mmss),
              const SizedBox(height: 12),
              _ModelNow(app: app, ar: ar),
              const SizedBox(height: 16),
              SectionCard(
                title: ar ? 'التحكم للعرض والمناقشة' : 'Demo controls',
                icon: Icons.tune,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      ar ? 'نوع النوبة' : 'Seizure type',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final t in SimSeizureType.values)
                          ChoiceChip(
                            label: Text(t.label(ar)),
                            selected: _type == t,
                            onSelected: (_) => setState(() => _type = t),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.of(
                          context,
                          RiskView.danger,
                        ).solid,
                        foregroundColor: AppColors.of(
                          context,
                          RiskView.danger,
                        ).onSolid,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () async {
                        await _ensureVirtual(app);
                        m.simulationControl((s) => s.startSeizure(_type));
                        if (context.mounted) {
                          AppSnack.info(
                            context,
                            ar
                                ? 'بدأت نوبة «${_type.label(true)}» من بدايتها. النموذج هو من يقرر الإنذار.'
                                : '«${_type.label(false)}» started from the beginning. The model decides on alerts.',
                          );
                        }
                      },
                      icon: const Icon(Icons.bolt),
                      label: Text(
                        sim.inEpisode
                            ? (ar
                                  ? 'ابدأ النوبة المختارة من جديد'
                                  : 'Start the chosen seizure over')
                            : (ar ? 'ابدأ نوبة الآن' : 'Start a seizure now'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: sim.inEpisode
                                ? () => m.simulationControl(
                                    (s) => s.restartSeizure(),
                                  )
                                : null,
                            icon: const Icon(Icons.replay),
                            label: Text(ar ? 'أعد النوبة' : 'Restart'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: sim.inEpisode
                                ? () =>
                                      m.simulationControl((s) => s.endSeizure())
                                : null,
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: Text(ar ? 'أنهِ النوبة' : 'End seizure'),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 28),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: sim.autoCycle,
                      onChanged: (v) =>
                          m.simulationControl((s) => s.setAutoCycle(v)),
                      title: Text(ar ? 'الدورة التلقائية' : 'Automatic cycle'),
                      subtitle: Text(
                        ar
                            ? 'فترة مستقرة ثم نوبة كاملة، وهكذا باستمرار'
                            : 'A calm period, then a full seizure, continuously',
                      ),
                    ),
                    Text(
                      ar ? 'مدة الفترة المستقرة' : 'Calm period length',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final minutes in const [1, 3, 5, 10])
                          ChoiceChip(
                            label: Text(ar ? '$minutes د' : '$minutes min'),
                            selected: sim.stableDuration.inMinutes == minutes,
                            onSelected: (_) => m.simulationControl(
                              (s) => s.setStableDuration(
                                Duration(minutes: minutes),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _AccuracyPanel(evaluation: m.evaluation, ar: ar),
              const SizedBox(height: 12),
              Text(
                sim.generator.library.isReal
                    ? (ar
                          ? 'الإشارات من تسجيلات EEG حقيقية (Bonn) لم تُستخدم في تدريب النماذج، مع تنويع لكل نوبة.'
                          : 'Signals come from real EEG recordings (Bonn) never used to train the models, varied per seizure.')
                    : (ar
                          ? 'مكتبة الإشارات الحقيقية غير متاحة؛ تُستخدم إشارات بديلة.'
                          : 'Real signal library unavailable; using fallback signals.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.sim,
    required this.truth,
    required this.ar,
    required this.mmss,
  });

  final SimulationScheduler sim;
  final SimTruth truth;
  final bool ar;
  final String Function(Duration) mmss;

  @override
  Widget build(BuildContext context) {
    final view = truth.phase == SimPhase.stable
        ? RiskView.safe
        : truth.phase.isSeizure
        ? RiskView.danger
        : RiskView.caution;
    final tone = AppColors.of(context, view);
    final ep = sim.episode;
    final remaining = sim.remaining;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ar ? 'الحساس يبث الآن' : 'Sensor is streaming',
            style: TextStyle(color: tone.foreground, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            truth.phase.label(ar),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: tone.foreground,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (ep != null) ...[
            const SizedBox(height: 4),
            Text(
              '${ep.type.label(ar)} · ${ar ? 'النوبة رقم' : 'Seizure #'}${ep.number}',
              style: TextStyle(color: tone.foreground),
            ),
          ],
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: truth.progress.clamp(0.0, 1.0),
            color: tone.solid,
            backgroundColor: tone.solid.withValues(alpha: .2),
          ),
          const SizedBox(height: 8),
          Text(
            ep == null
                ? (sim.autoCycle
                      ? (ar
                            ? 'النوبة التالية بعد ${mmss(remaining)}'
                            : 'Next seizure in ${mmss(remaining)}')
                      : (ar
                            ? 'الدورة التلقائية متوقفة'
                            : 'Automatic cycle is off'))
                : (ar
                      ? 'متبقٍ في هذه المرحلة ${mmss(remaining)}'
                      : '${mmss(remaining)} left in this phase'),
            style: TextStyle(
              color: tone.foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the model is deciding right now (never the simulator's truth).
class _ModelNow extends StatelessWidget {
  const _ModelNow({required this.app, required this.ar});

  final AppState app;
  final bool ar;

  @override
  Widget build(BuildContext context) {
    final a = app.monitoring.latestAssessment;
    final engine = a?.features['engine'];
    final onPhone = engine == 'edge_onnx' || engine == 'edge_multimodal';
    final forecast = (a?.features['preictal_prob'] as num?)?.toDouble();
    return SectionCard(
      title: ar ? 'قرار النموذج الآن' : 'Model decision now',
      icon: Icons.psychology_outlined,
      trailing: RiskBadge(view: app.riskView, dense: true),
      child: Column(
        children: [
          LabeledValue(
            label: ar ? 'النموذج' : 'Model',
            value: a == null
                ? '—'
                : onPhone
                ? (ar ? 'المحلي (على الهاتف)' : 'Phone (local)')
                : (ar ? 'السحابي' : 'Cloud'),
          ),
          LabeledValue(
            label: ar ? 'احتمال النوبة القادمة' : 'Seizure forecast',
            value: forecast == null ? '—' : '${(forecast * 100).round()}%',
          ),
          LabeledValue(
            label: ar ? 'نبض القلب' : 'Heart rate',
            value: app.monitoring.latestReading == null
                ? '—'
                : '${app.monitoring.latestReading!.hr.round()}',
          ),
        ],
      ),
    );
  }
}

class _AccuracyPanel extends StatelessWidget {
  const _AccuracyPanel({required this.evaluation, required this.ar});

  final ModelEvaluation evaluation;
  final bool ar;

  String _pct(double? v) => v == null ? '—' : '${(v * 100).round()}%';

  Widget _column(BuildContext context, String title, EngineMetrics m) {
    final rows = <(String, String)>[
      (ar ? 'النوافذ المقيّمة' : 'Windows scored', '${m.windows}'),
      (ar ? 'النوبات' : 'Seizures', '${m.seizureEpisodes}'),
      (ar ? 'نسبة الاكتشاف' : 'Detected', _pct(m.sensitivity)),
      (
        ar ? 'زمن الاكتشاف' : 'Time to detect',
        m.meanDetectionSeconds == null
            ? '—'
            : '${m.meanDetectionSeconds!.toStringAsFixed(0)} ${ar ? 'ث' : 's'}',
      ),
      (ar ? 'تنبأ قبل النوبة' : 'Warned before', _pct(m.forecastRate)),
      (
        ar ? 'إنذارات كاذبة/ساعة' : 'False alarms/hour',
        m.falseAlarmsPerHour == null
            ? '—'
            : m.falseAlarmsPerHour!.toStringAsFixed(1),
      ),
    ];
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      k,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cloud = evaluation.metricsFor(EvalEngine.cloud);
    final phone = evaluation.metricsFor(EvalEngine.phone);
    return SectionCard(
      title: ar ? 'دقة النموذجين' : 'Model accuracy',
      icon: Icons.analytics_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            ar
                ? 'مقارنة ما بثّه الحساس فعلًا بما قرره كل نموذج على الإشارة نفسها.'
                : 'What the sensor really streamed vs what each model decided on the same signal.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _column(context, ar ? '☁️ السحابي' : '☁️ Cloud', cloud),
              const SizedBox(width: 16),
              _column(context, ar ? '📱 المحلي' : '📱 Phone', phone),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: evaluation.records.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: evaluation.toCsv()),
                          );
                          if (context.mounted) {
                            AppSnack.success(
                              context,
                              ar
                                  ? 'نُسخت النتائج (CSV) — الصقها في Excel أو التقرير.'
                                  : 'Results copied as CSV — paste into Excel or your report.',
                            );
                          }
                        },
                  icon: const Icon(Icons.copy_all_outlined),
                  label: Text(ar ? 'نسخ النتائج CSV' : 'Copy results CSV'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: evaluation.records.isEmpty ? null : evaluation.clear,
                child: Text(ar ? 'تصفير' : 'Reset'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
