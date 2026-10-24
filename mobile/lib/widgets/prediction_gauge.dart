import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/risk_view.dart';
import '../core/ui/common.dart';
import '../l10n/app_localizations.dart';
import '../models/prediction_state.dart';

/// Seizure-forecast gauge: `P(preictal)` as a hand-painted half arc.
///
/// fl_chart ships no radial gauge, so the arc is a [CustomPainter]. Three rules
/// from `docs/frontend-plan-ar.md` apply:
///
/// * The colour comes from [AppColors] (§2.4), so it is legible in dark mode and
///   identical to every other risk surface in the app.
/// * The band is stated in **words and an icon** as well as colour (§2.4/§7).
/// * The provenance is always visible, and a simulated forecast says so out loud
///   (§11.2) — a demo number must never be able to pass for a model output.
class PredictionGauge extends StatelessWidget {
  const PredictionGauge({super.key, required this.prediction});

  final PredictionState prediction;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final view = prediction.band.bandView;
    final colors = AppColors.of(context, view);
    final pct = (prediction.preictalProb * 100).clamp(0, 100).round();

    return SectionCard(
      title: l.preictalProb,
      icon: Icons.online_prediction_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            label: '${l.preictalProb} $pct٪ — ${_bandLabel(view, l)}',
            child: ExcludeSemantics(
              child: SizedBox(
                height: 132,
                child: CustomPaint(
                  painter: _GaugePainter(
                    value: prediction.preictalProb.clamp(0.0, 1.0).toDouble(),
                    color: colors.solid,
                    track: theme.colorScheme.surfaceContainerHighest,
                  ),
                  child: Align(
                    alignment: const Alignment(0, 0.45),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$pct%',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: colors.foreground,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              AppColors.iconFor(view),
                              size: 16,
                              color: colors.foreground,
                            ),
                            Gap.hXs,
                            Text(
                              _bandLabel(view, l),
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: colors.foreground,
                                fontWeight: FontWeight.w700,
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
          ),
          if (prediction.drivers != null && prediction.drivers!.isNotEmpty) ...[
            Gap.vMd,
            Text(
              l.drivers,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Gap.vXs,
            _DriversRow(drivers: prediction.drivers!, view: view),
          ],
          Gap.vMd,
          ForecastSourceNote(prediction: prediction),
        ],
      ),
    );
  }

  static String _bandLabel(RiskView view, AppLocalizations l) => switch (view) {
    RiskView.safe => l.riskSafeTitle,
    RiskView.caution => l.riskCautionTitle,
    RiskView.danger => l.riskDangerTitle,
    RiskView.unknown => l.riskUnknownTitle,
  };
}

/// Where the forecast came from — and, when it is the offline heuristic rather
/// than the trained model, an explicit warning that the number is simulated.
///
/// §11.2: «لا تُقدِّم مخرجات محاكاة كأنها نتائج نموذج». This is that rule as a
/// widget, so no screen can render a forecast without carrying its provenance.
class ForecastSourceNote extends StatelessWidget {
  const ForecastSourceNote({super.key, required this.prediction});

  final PredictionState prediction;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isModel = prediction.isModel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabeledValue(
          label: l.forecastSection,
          value: isModel ? l.forecastSourceModel : l.forecastSourceHeuristic,
          icon: isModel ? Icons.psychology_outlined : Icons.science_outlined,
        ),
        Gap.vSm,
        InfoNote(
          text: l.forecastResearchWarning,
          icon: Icons.science_outlined,
          view: RiskView.caution,
        ),
        if (!isModel) ...[
          Gap.vSm,
          InfoNote(
            text: l.forecastHeuristicWarning,
            icon: Icons.warning_amber_rounded,
            view: RiskView.caution,
          ),
        ],
      ],
    );
  }
}

/// Auditable "why": per-channel contribution to the forecast, as chips, so the
/// prediction is explainable instead of a black box.
class _DriversRow extends StatelessWidget {
  const _DriversRow({required this.drivers, required this.view});

  final Map<String, double> drivers;
  final RiskView view;

  static String _label(String key, AppLocalizations l) => switch (key) {
    'eeg' => l.driverEeg,
    'hr' => l.driverHr,
    'motion' => l.driverMotion,
    'ecg' => l.driverEcg,
    _ => key,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = AppColors.of(context, view);
    final total = drivers.values.fold<double>(0, (a, b) => a + b);
    final entries = drivers.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: Gap.xs,
      runSpacing: Gap.xs,
      children: [
        for (final e in entries)
          Container(
            padding: Insets.chip,
            decoration: BoxDecoration(
              color: colors.container,
              borderRadius: Radii.rPill,
              border: Border.all(color: colors.border),
            ),
            child: Text(
              total > 0
                  ? '${_label(e.key, l)} ${((e.value / total) * 100).round()}%'
                  : _label(e.key, l),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colors.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.value,
    required this.color,
    required this.track,
  });

  final double value; // 0..1
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    // Half arc: 180° from the left (π) sweeping clockwise over the top to the
    // right (2π), so the fill grows left→right = low→high.
    const startAngle = math.pi;
    const sweep = math.pi;

    final radius = math.min(size.width / 2 - stroke / 2, size.height - stroke);
    final center = Offset(size.width / 2, size.height - stroke / 2);
    final arcRect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final valuePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(arcRect, startAngle, sweep, false, trackPaint);
    canvas.drawArc(
      arcRect,
      startAngle,
      sweep * value.clamp(0.0, 1.0),
      false,
      valuePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.value != value || old.color != color || old.track != track;
}
