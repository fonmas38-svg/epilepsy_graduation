import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/enums.dart';
import '../models/prediction_state.dart';

/// Custom-painted seizure-forecast gauge.
///
/// fl_chart (^0.69.2) ships no radial-gauge widget, so this is a hand-painted
/// arc. It renders `P(preictal)` on the SAME colour palette as [StatusBadge]
/// (green→amber→red) so detection and prediction read as one system. Purely
/// presentational — it never computes risk, only displays [PredictionState].
class PredictionGauge extends StatelessWidget {
  const PredictionGauge({super.key, required this.prediction});

  final PredictionState prediction;

  // Shared risk palette (identical hex to StatusBadge) → one colour system.
  static const _stable = Color(0xFF1B7F4E);
  static const _watch = Color(0xFFB7791F);
  static const _high = Color(0xFFB42318);

  Color get _color => switch (prediction.band) {
        RiskLabel.stable => _stable,
        RiskLabel.watch => _watch,
        RiskLabel.highRisk => _high,
      };

  String get _bandLabelAr => switch (prediction.band) {
        RiskLabel.stable => 'استقرار',
        RiskLabel.watch => 'ارتفاع محتمل',
        RiskLabel.highRisk => 'خطر وشيك',
      };

  @override
  Widget build(BuildContext context) {
    final pct = (prediction.preictalProb * 100).clamp(0, 100).round();
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: _color.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.online_prediction, size: 18, color: _color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('احتمال اقتراب نوبة',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 132,
              child: CustomPaint(
                painter: _GaugePainter(
                  value: prediction.preictalProb.clamp(0.0, 1.0).toDouble(),
                  color: _color,
                  track: Theme.of(context).dividerColor.withValues(alpha: 0.25),
                ),
                child: Align(
                  alignment: const Alignment(0, 0.45),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$pct%',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(
                                  color: _color, fontWeight: FontWeight.bold)),
                      Text(_bandLabelAr,
                          style: TextStyle(
                              color: _color, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
            if (prediction.drivers != null && prediction.drivers!.isNotEmpty) ...[
              const SizedBox(height: 6),
              _DriversRow(drivers: prediction.drivers!, color: _color),
            ],
          ],
        ),
      ),
    );
  }
}

/// Auditable "why" (#22): per-channel contributions to the forecast, shown as
/// compact chips so the prediction is explainable, not a black box.
class _DriversRow extends StatelessWidget {
  const _DriversRow({required this.drivers, required this.color});

  final Map<String, double> drivers;
  final Color color;

  static const _labelsAr = {
    'eeg': 'الدماغ',
    'hr': 'النبض',
    'motion': 'الحركة',
    'ecg': 'القلب',
  };

  @override
  Widget build(BuildContext context) {
    final total = drivers.values.fold<double>(0, (a, b) => a + b);
    final entries = drivers.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final e in entries)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Text(
              total > 0
                  ? '${_labelsAr[e.key] ?? e.key} ${((e.value / total) * 100).round()}%'
                  : (_labelsAr[e.key] ?? e.key),
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.value, required this.color, required this.track});

  final double value; // 0..1
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    // Top "rainbow" arc: 180° from left (π) sweeping clockwise through the top
    // (3π/2, up) to the right (2π). Value fills left→right = low→high.
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
        arcRect, startAngle, sweep * value.clamp(0.0, 1.0), false, valuePaint);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.value != value || old.color != color || old.track != track;
}
