import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/models.dart';

class AlertsList extends StatelessWidget {
  const AlertsList({
    super.key,
    required this.alerts,
    required this.onAcknowledge,
  });

  final List<AlertItem> alerts;
  final Future<void> Function(String id) onAcknowledge;

  Color _severityColor(String severity) => switch (severity) {
        'critical' => const Color(0xFFB42318),
        'warning' => const Color(0xFFB7791F),
        _ => const Color(0xFF1B4965),
      };

  @override
  Widget build(BuildContext context) {
    if (alerts.isEmpty) {
      return const Center(child: Text('لا توجد تنبيهات'));
    }
    final fmt = DateFormat('MM-dd HH:mm');
    return ListView.separated(
      itemCount: alerts.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final a = alerts[index];
        return ListTile(
          leading: Icon(Icons.notification_important, color: _severityColor(a.severity)),
          title: Text(a.message),
          subtitle: Text('${fmt.format(a.timestamp)} · ${a.severity}'),
          trailing: a.acknowledged
              ? const Icon(Icons.check_circle, color: Colors.green)
              : TextButton(
                  onPressed: () => onAcknowledge(a.id),
                  child: const Text('إقرار'),
                ),
        );
      },
    );
  }
}
