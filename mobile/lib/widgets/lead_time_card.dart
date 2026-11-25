import 'package:flutter/material.dart';

import '../core/ui/common.dart';
import '../l10n/app_localizations.dart';
import '../models/prediction_state.dart';

/// Classifier scores cannot be converted into a countdown to seizure onset.
class LeadTimeCard extends StatelessWidget {
  const LeadTimeCard({super.key, required this.prediction, this.engine});
  final PredictionState prediction;

  /// `engine` of the latest assessment (e.g. `edge_onnx` offline).
  final String? engine;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SectionCard(
      title: l.leadTime,
      icon: Icons.timer_off_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.forecastResearchWarning),
          if (engine == 'edge_onnx') ...[
            const SizedBox(height: 8),
            Text(
              l.isArabic
                  ? 'التنبؤ المبكر متاح عبر السحابة فقط. يعمل الآن على جهازك الكشف المحلي للنوبات الجارية، ولا يقدّم وقتاً مسبقاً.'
                  : 'Early forecasting is cloud-only. On-device detection of ongoing seizures is running now; it gives no advance time.',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }
}
