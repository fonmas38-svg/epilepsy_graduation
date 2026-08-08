import 'dart:async';

import 'package:flutter/material.dart';

import '../models/prediction_state.dart';

/// Lead-time countdown for the seizure forecast.
///
/// Shows "نوبة محتملة خلال ~N دقيقة" with a live 1-second timer that interpolates
/// the estimated lead-time *between* backend polls, so the countdown feels
/// continuous rather than stepping only when a new [PredictionState] arrives.
/// Also carries a simulated-vs-model chip (#23) reusing the `_EngineChip`
/// visual pattern so the forecast's provenance is always visible.
class LeadTimeCard extends StatefulWidget {
  const LeadTimeCard({super.key, required this.prediction});

  final PredictionState prediction;

  @override
  State<LeadTimeCard> createState() => _LeadTimeCardState();
}

class _LeadTimeCardState extends State<LeadTimeCard> {
  Timer? _timer;
  // Lead-time in seconds, interpolated locally between polls.
  double? _remainingSec;
  DateTime _lastSync = DateTime.now();

  @override
  void initState() {
    super.initState();
    _syncFrom(widget.prediction);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _decay());
  }

  @override
  void didUpdateWidget(covariant LeadTimeCard old) {
    super.didUpdateWidget(old);
    // A fresh poll resets the interpolation anchor.
    if (widget.prediction.leadTimeMin != old.prediction.leadTimeMin ||
        widget.prediction.preictalProb != old.prediction.preictalProb) {
      _syncFrom(widget.prediction);
    }
  }

  void _syncFrom(PredictionState p) {
    final min = p.leadTimeMin;
    _remainingSec = min == null ? null : (min * 60).clamp(0, 24 * 3600).toDouble();
    _lastSync = DateTime.now();
  }

  void _decay() {
    if (_remainingSec == null) return;
    setState(() {
      _remainingSec = (_remainingSec! - 1).clamp(0, 24 * 3600).toDouble();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _countdownAr {
    final s = _remainingSec;
    if (s == null) return 'غير متاح';
    if (s <= 0) return 'وشيكة الآن';
    final totalMin = s / 60.0;
    if (totalMin >= 1) {
      return '~${totalMin.toStringAsFixed(totalMin >= 10 ? 0 : 1)} دقيقة';
    }
    return '~${s.round()} ثانية';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prediction;
    final predicted = p.predicted;
    final accent = predicted ? const Color(0xFFB42318) : const Color(0xFF1B4965);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: accent.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(predicted ? Icons.notification_important : Icons.timer_outlined,
                    size: 18, color: accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    predicted ? 'تنبيه مبكر: نوبة محتملة' : 'زمن الاستباق المتوقع',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: accent, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('نوبة محتملة خلال',
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(width: 8),
                Text(
                  _countdownAr,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(color: accent, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (p.horizonMin != null) ...[
              const SizedBox(height: 4),
              Text('أفق التنبؤ: ${p.horizonMin!.toStringAsFixed(0)} دقيقة',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 10),
            _SourceChip(prediction: p),
          ],
        ),
      ),
    );
  }
}

/// Simulated-vs-model provenance chip (#23), mirroring the `_EngineChip` look
/// used on the home screen so the forecast's source is honest and visible.
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.prediction});

  final PredictionState prediction;

  @override
  Widget build(BuildContext context) {
    final isModel = prediction.isModel;
    final color = isModel ? Colors.indigo : Colors.teal;
    final icon = isModel ? Icons.psychology : Icons.science_outlined;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(
              'مصدر التنبؤ: ${prediction.sourceLabelAr}',
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
