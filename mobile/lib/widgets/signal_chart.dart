import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import '../core/ui/states.dart';
import '../l10n/app_localizations.dart';

/// A single physiological channel drawn as a sparkline.
///
/// Three deliberate choices, all from `docs/frontend-plan-ar.md`:
///
/// * **No animation.** `duration: Duration.zero` — §7 forbids fast motion or
///   anything that flashes, and a chart that re-tweens on every 1 Hz tick is
///   exactly the kind of movement a photosensitive patient should not be shown.
/// * **Auto-scaled Y axis.** The previous fixed ±2.5 window silently clipped any
///   real signal that left it, which makes a flat line mean two different things.
/// * **No embedded strings.** The empty state comes from the string table (§2.3)
///   and the colour comes from the caller, so dark mode stays legible (§2.4).
class SignalChart extends StatelessWidget {
  const SignalChart({
    super.key,
    required this.title,
    required this.values,
    this.color,
    this.height = 120,
    this.unitLabel,
  });

  final String title;
  final List<double> values;

  /// Channel colour. Defaults to the theme's primary so a caller that has no
  /// opinion still gets something with adequate contrast in both themes.
  final Color? color;

  final double height;

  /// Optional unit shown next to the title (e.g. «bpm»). Never a raw key.
  final String? unitLabel;

  /// Y-axis window: the data's own range, padded by 10% so the trace never
  /// touches the frame, with a floor on the span so an almost-flat channel does
  /// not get magnified into dramatic noise.
  (double, double) _window() {
    var lo = values.first;
    var hi = values.first;
    for (final v in values) {
      if (v.isNaN || v.isInfinite) continue;
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    var span = hi - lo;
    if (span < 0.5) {
      final mid = (hi + lo) / 2;
      lo = mid - 0.25;
      hi = mid + 0.25;
      span = 0.5;
    }
    final pad = span * 0.1;
    return (lo - pad, hi + pad);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final line = color ?? theme.colorScheme.primary;
    final heading = [title, if (unitLabel != null) '($unitLabel)'].join(' ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Gap.vXs,
        SizedBox(
          height: height,
          child: values.isEmpty
              ? EmptyState(
                  title: l.chartNoData,
                  icon: Icons.show_chart_outlined,
                  compact: true,
                )
              : _chart(line),
        ),
      ],
    );
  }

  Widget _chart(Color line) {
    final (minY, maxY) = _window();
    // The trace is decorative: the numbers that matter are stated in text
    // elsewhere on every screen that uses this, so the chart itself is excluded
    // from the screen reader rather than read out as hundreds of samples.
    return ExcludeSemantics(
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          minX: 0,
          maxX: (values.length - 1).clamp(1, double.maxFinite).toDouble(),
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (var i = 0; i < values.length; i++)
                  FlSpot(i.toDouble(), values[i].isFinite ? values[i] : minY),
              ],
              isCurved: true,
              curveSmoothness: 0.2,
              barWidth: 2,
              color: line,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: line.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
        // §7: no animation anywhere in this app.
        duration: Duration.zero,
      ),
    );
  }
}
