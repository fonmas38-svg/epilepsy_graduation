import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';

/// Offline model-performance panel (#20) for the doctor screen. Fetches
/// `GET /model/metrics` and renders the trained models' per-window clinical
/// metrics (sensitivity / specificity / FPR-per-hour). The CHB-MIT preictal
/// PREDICTION model is the headline; the Bonn detection model follows. Fully
/// additive and read-only — degrades to a clear "unavailable" state when the
/// backend is offline or a model hasn't been trained yet.
class MetricsPanel extends StatefulWidget {
  const MetricsPanel({super.key});

  @override
  State<MetricsPanel> createState() => _MetricsPanelState();
}

class _MetricsPanelState extends State<MetricsPanel> {
  late Future<Map<String, dynamic>?> _future;

  // Ordered so the PREDICTION model is presented first (the thesis headline).
  static const _blocks = [
    ('preictal_chbmit', 'تنبؤ بالنوبة (preictal ضد interictal)', 'CHB-MIT · chb01 · لكل نافذة'),
    ('detection_bonn', 'كشف النوبة (ictal ضد non-ictal)', 'Bonn · لكل نافذة'),
  ];

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().api.modelMetrics();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final data = snap.data;
        if (data == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('تعذّر جلب مقاييس النموذج — تحقّق من اتصال الخادم.'),
          );
        }
        final reports = (data['reports'] as Map?)?.cast<String, dynamic>() ?? {};
        final engineLive = data['prediction_engine_available'] == true;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _EngineLine(live: engineLive),
            const SizedBox(height: 8),
            for (final (key, title, subtitle) in _blocks)
              _MetricsBlock(
                title: title,
                subtitle: subtitle,
                report: (reports[key] as Map?)?.cast<String, dynamic>(),
              ),
          ],
        );
      },
    );
  }
}

/// Whether the live forecast is currently backed by the real model or the
/// honest heuristic — stated plainly so the demo is never misrepresented.
class _EngineLine extends StatelessWidget {
  const _EngineLine({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    final color = live ? const Color(0xFF1B7F4E) : const Color(0xFF1B4965);
    final text = live
        ? 'المحرك الحيّ للتنبؤ: نموذج عصبي مُدرّب (CNN-LSTM)'
        : 'المحرك الحيّ للتنبؤ: محاكاة تنبؤية شفافة (النموذج المُدرّب متاح دون اتصال)';
    return Row(
      children: [
        Icon(live ? Icons.verified : Icons.science, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _MetricsBlock extends StatelessWidget {
  const _MetricsBlock({required this.title, required this.subtitle, required this.report});

  final String title;
  final String subtitle;
  final Map<String, dynamic>? report;

  /// Prefer the clinically-tuned test metrics, then val-tuned, then default 0.5.
  Map<String, dynamic>? _pickMetrics(Map<String, dynamic> metrics) {
    for (final k in const ['test_at_tuned_threshold', 'val_tuned_threshold', 'test_at_0.5']) {
      final m = metrics[k];
      if (m is Map) return m.cast<String, dynamic>();
    }
    return null;
  }

  String _pct(dynamic v) => v is num ? '${(v * 100).toStringAsFixed(1)}%' : '—';
  String _num(dynamic v) => v is num ? v.toStringAsFixed(1) : '—';

  @override
  Widget build(BuildContext context) {
    final available = report?['available'] == true;
    final metrics = available ? (report?['metrics'] as Map?)?.cast<String, dynamic>() : null;
    final picked = metrics == null ? null : _pickMetrics(metrics);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            Text(subtitle, style: const TextStyle(color: Colors.black54, fontSize: 12)),
            const SizedBox(height: 8),
            if (picked == null)
              Text(
                available
                    ? 'الملف موجود لكن بصيغة غير متوقعة.'
                    : 'غير مُدرّب بعد — شغّل research/scripts/train.py --dataset chbmit لإنتاج المقاييس.',
                style: const TextStyle(color: Color(0xFFB7791F)),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _MetricChip(label: 'الحساسية', value: _pct(picked['sensitivity']), color: const Color(0xFF1B7F4E)),
                  _MetricChip(label: 'النوعية', value: _pct(picked['specificity']), color: const Color(0xFF1B4965)),
                  _MetricChip(label: 'إنذار كاذب/ساعة', value: _num(picked['fpr_per_hour']), color: const Color(0xFFB7791F)),
                  if (picked['threshold'] != null)
                    _MetricChip(label: 'العتبة', value: _num(picked['threshold']), color: Colors.blueGrey),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 11)),
          Text(value, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
