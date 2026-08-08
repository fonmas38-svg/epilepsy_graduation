import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../providers/app_state.dart';
import '../../widgets/prediction_history_view.dart';

class MedicalRecordView extends StatelessWidget {
  const MedicalRecordView({super.key, required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final profile = state.auth.patientById(patientId);
    if (profile == null) {
      return const Center(child: Text('لا يوجد سجل'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('السجل الطبي', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        ListTile(
          title: const Text('التشخيص'),
          subtitle: Text(profile.diagnosis),
        ),
        ListTile(
          title: const Text('الأدوية'),
          subtitle: Text(profile.medications.isEmpty ? '—' : profile.medications.join('\n')),
        ),
        ListTile(
          title: const Text('الحالة الحالية'),
          subtitle: Text(profile.currentStatus.apiValue),
        ),
        ListTile(
          title: const Text('آخر تحديث'),
          subtitle: Text(profile.lastUpdated.toIso8601String()),
        ),
        const SizedBox(height: 16),
        Text('سجل أحداث التنبؤ', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        PredictionHistoryView(patientId: patientId),
      ],
    );
  }
}
