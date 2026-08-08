import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

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
    final db = context.read<AppState>().db;
    return FutureBuilder<List<PredictionEvent>>(
      future: db.predictionEventsFor(patientId),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final events = snap.data ?? const <PredictionEvent>[];
        if (events.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'لا توجد أحداث تنبؤ بعد. عند إطلاق تنبيه مبكر (وتصعيده أو إلغائه '
              'خلال مهلة الـ30 ثانية) سيُسجَّل هنا كدليل على التنبؤ المسبق.',
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Summary(events: events),
            const SizedBox(height: 8),
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
      color: const Color(0xFF1B4965).withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${events.length} حدث تنبؤ مُسجَّل',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _Stat(label: 'تصعيد', value: '$escalated', color: const Color(0xFFB42318)),
                _Stat(label: 'إنذار كاذب', value: '$cancelled', color: const Color(0xFFB7791F)),
                if (avgLead != null)
                  _Stat(
                    label: 'متوسط المهلة',
                    value: '~${avgLead.toStringAsFixed(1)} د',
                    color: const Color(0xFF1B7F4E),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text('$label: $value',
          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final PredictionEvent event;

  (String, Color, IconData) get _outcome => switch (event.outcome) {
        'escalated' => ('تصعيد إلى تنبيه', const Color(0xFFB42318), Icons.notifications_active),
        'cancelled_false_alarm' =>
          ('إلغاء (إنذار كاذب)', const Color(0xFFB7791F), Icons.cancel_schedule_send),
        'onset_confirmed' =>
          ('تأكيد بدء النوبة', const Color(0xFF7A1212), Icons.bolt),
        _ => (event.outcome, const Color(0xFF1B4965), Icons.timeline),
      };

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = _outcome;
    final fmt = DateFormat('MM/dd HH:mm');
    final isModel = event.source == 'cnn_lstm_preictal';
    final parts = <String>[
      'احتمالية ${(event.preictalProb * 100).toStringAsFixed(0)}%',
      if (event.leadTimeMin != null) 'مهلة ~${event.leadTimeMin!.toStringAsFixed(1)} د',
      if (event.horizonMin != null) 'أفق ${event.horizonMin!.toStringAsFixed(0)} د',
      isModel ? 'نموذج عصبي' : 'محاكاة',
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
