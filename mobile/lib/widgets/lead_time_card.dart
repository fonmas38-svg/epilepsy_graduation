import 'package:flutter/material.dart';

import '../core/ui/common.dart';
import '../l10n/app_localizations.dart';
import '../models/prediction_state.dart';

/// Classifier scores cannot be converted into a countdown to seizure onset.
class LeadTimeCard extends StatelessWidget {
  const LeadTimeCard({super.key, required this.prediction});
  final PredictionState prediction;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SectionCard(
      title: l.leadTime,
      icon: Icons.timer_off_outlined,
      child: Text(l.forecastResearchWarning),
    );
  }
}
