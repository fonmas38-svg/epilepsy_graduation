import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/risk_view.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_state.dart';

/// Offline model-performance panel (#20) for the doctor screen. Fetches
/// `GET /model/metrics` and renders the trained models' per-window clinical
/// metrics (sensitivity / specificity / FPR-per-hour). The preictal PREDICTION
/// model is the headline; the detection model follows. Fully additive and
/// read-only — degrades to a clear "unavailable" state when the backend is
/// offline or a model hasn't been trained yet.
class MetricsPanel extends StatefulWidget {
  const MetricsPanel({super.key});

  @override
  State<MetricsPanel> createState() => _MetricsPanelState();
}

class _MetricsPanelState extends State<MetricsPanel> {
  late Future<Map<String, dynamic>?> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().api.modelMetrics();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Ordered so the PREDICTION model is presented first (the thesis headline).
    final blocks = [
      ('preictal_chbmit', l.taskPrediction),
      ('detection_bonn', l.taskDetection),
    ];
    return FutureBuilder<Map<String, dynamic>?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: Gap.md),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final data = snap.data;
        if (data == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Text(l.metricsUnavailable),
          );
        }
        final reports =
            (data['reports'] as Map?)?.cast<String, dynamic>() ?? {};
        final engineLive = data['prediction_engine_available'] == true;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _EngineLine(live: engineLive),
            const SizedBox(height: Gap.sm),
            for (final (key, title) in blocks)
              _MetricsBlock(
                title: title,
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
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final color = live
        ? AppColors.of(context, RiskView.safe).foreground
        : scheme.primary;
    return Row(
      children: [
        Icon(live ? Icons.verified : Icons.science, size: 16, color: color),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: Text(
            live ? l.liveEngine : l.modelAvailableOffline,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricsBlock extends StatelessWidget {
  const _MetricsBlock({required this.title, required this.report});

  final String title;
  final Map<String, dynamic>? report;

  /// Prefer the clinically-tuned test metrics, then val-tuned, then default 0.5.
  Map<String, dynamic>? _pickMetrics(Map<String, dynamic> metrics) {
    for (final k in const [
      'test_at_tuned_threshold',
      'val_tuned_threshold',
      'test_at_0.5',
    ]) {
      final m = metrics[k];
      if (m is Map) return m.cast<String, dynamic>();
    }
    return null;
  }

  String _pct(dynamic v) => v is num ? '${(v * 100).toStringAsFixed(1)}%' : '—';
  String _num(dynamic v) => v is num ? v.toStringAsFixed(1) : '—';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final caution = AppColors.of(context, RiskView.caution).foreground;
    final safe = AppColors.of(context, RiskView.safe).foreground;
    final available = report?['available'] == true;
    final metrics = available
        ? (report?['metrics'] as Map?)?.cast<String, dynamic>()
        : null;
    final picked = metrics == null ? null : _pickMetrics(metrics);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            Text(l.perWindow, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            if (picked == null)
              Text(
                available ? l.modelBadFormat : l.modelNotTrained,
                style: TextStyle(color: caution),
              )
            else
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  _MetricChip(
                    label: l.colSensitivity,
                    value: _pct(picked['sensitivity']),
                    color: safe,
                  ),
                  _MetricChip(
                    label: l.colSpecificity,
                    value: _pct(picked['specificity']),
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  _MetricChip(
                    label: l.colFalseAlarmsPerHour,
                    value: _num(picked['fpr_per_hour']),
                    color: caution,
                  ),
                  if (picked['threshold'] != null)
                    _MetricChip(
                      label: l.colThreshold,
                      value: _num(picked['threshold']),
                      color: Theme.of(context).colorScheme.outline,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
