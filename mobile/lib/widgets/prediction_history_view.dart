import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/risk_view.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../providers/app_state.dart';

/// Read-only history of prediction events (#19) — the audit trail that the
/// system forecast seizures *ahead of time*. Every pre-alert that escalated or
/// was cancelled as a false alarm is logged with the probability, the estimated
/// lead-time at fire, the horizon, and whether a real model or the heuristic
/// produced it. Purely additive: reads the `prediction_events` table only.
class PredictionHistoryView extends StatelessWidget {
  const PredictionHistoryView({super.key, required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final db = context.read<AppState>().db;
    return FutureBuilder<List<PredictionEvent>>(
      future: db.predictionEventsFor(patientId),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: Gap.md),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final events = snap.data ?? const <PredictionEvent>[];
        if (events.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Text(l.noPredictionEvents),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Summary(events: events),
            const SizedBox(height: Gap.sm),
            ...events.map((e) => _EventTile(event: e)),
          ],
        );
      },
    );
  }
}

/// Aggregate line: how many forecasts fired, how they resolved, and the mean
/// lead-time we bought at fire time (the headline "we predict ahead" number).
class _Summary extends StatelessWidget {
  const _Summary({required this.events});

  final List<PredictionEvent> events;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final danger = AppColors.of(context, RiskView.danger).foreground;
    final caution = AppColors.of(context, RiskView.caution).foreground;
    final safe = AppColors.of(context, RiskView.safe).foreground;
    final primary = Theme.of(context).colorScheme.primary;

    final escalated = events.where((e) => e.outcome == 'escalated').length;
    final cancelled =
        events.where((e) => e.outcome == 'cancelled_false_alarm').length;
    final leads = events
        .map((e) => e.leadTimeMin)
        .whereType<double>()
        .toList(growable: false);
    final avgLead = leads.isEmpty
        ? null
        : leads.reduce((a, b) => a + b) / leads.length;
    return Card(
      color: primary.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.predictionEventsCount(events.length),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.xs,
              children: [
                _Stat(label: l.escalatedShort, value: '$escalated', color: danger),
                _Stat(label: l.falseAlarm, value: '$cancelled', color: caution),
                if (avgLead != null)
                  _Stat(
                    label: l.avgLeadTime,
                    value: l.minutesApprox(avgLead.toStringAsFixed(1)),
                    color: safe,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final PredictionEvent event;

  (String, Color, IconData) _outcome(BuildContext context) {
    final l = AppLocalizations.of(context);
    final danger = AppColors.of(context, RiskView.danger).foreground;
    final caution = AppColors.of(context, RiskView.caution).foreground;
    final primary = Theme.of(context).colorScheme.primary;

    return switch (event.outcome) {
      'escalated' => (l.outcomeEscalated, danger, Icons.notifications_active),
      'cancelled_false_alarm' => (l.outcomeFalseAlarm, caution, Icons.cancel_schedule_send),
      'onset_confirmed' => (l.outcomeOnsetConfirmed, danger, Icons.bolt),
      _ => (event.outcome, primary, Icons.timeline),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final (label, color, icon) = _outcome(context);
    final fmt = DateFormat('MM/dd HH:mm');
    final isModel = event.source == 'cnn_lstm_preictal';
    final parts = <String>[
      '${l.preictalProb}: ${(event.preictalProb * 100).toStringAsFixed(0)}%',
      if (event.leadTimeMin != null)
        '${l.leadTime}: ${l.minutesApprox(event.leadTimeMin!.toStringAsFixed(1))}',
      if (event.horizonMin != null)
        '${l.horizonShort}: ${l.minutes(event.horizonMin!.toStringAsFixed(0))}',
      isModel ? l.forecastSourceModel : l.forecastSourceHeuristic,
    ];
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        subtitle: Text('${fmt.format(event.firedAt)}  ·  ${parts.join('  ·  ')}'),
      ),
    );
  }
}
