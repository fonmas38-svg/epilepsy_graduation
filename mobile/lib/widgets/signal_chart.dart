import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

class SignalChart extends StatelessWidget {
  const SignalChart({
    super.key,
    required this.title,
    required this.values,
    required this.color,
  });

  final String title;
  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    for (var i = 0; i < values.length; i++) {
      spots.add(FlSpot(i.toDouble(), values[i]));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          height: 120,
          child: spots.isEmpty
              ? const Center(child: Text('لا توجد بيانات بعد'))
              : LineChart(
                  LineChartData(
                    minY: -2.5,
                    maxY: 2.5,
                    titlesData: const FlTitlesData(show: false),
                    gridData: const FlGridData(show: true, drawVerticalLine: false),
                    borderData: FlBorderData(show: false),
                    lineBarsData: [
                      LineChartBarData(
                        spots: spots,
                        isCurved: true,
                        color: color,
                        barWidth: 2,
                        dotData: const FlDotData(show: false),
                        belowBarData: BarAreaData(
                          show: true,
                          color: color.withValues(alpha: 0.12),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
