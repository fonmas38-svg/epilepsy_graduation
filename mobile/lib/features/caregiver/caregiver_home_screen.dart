import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../providers/app_state.dart';
import '../../widgets/status_badge.dart';
import '../shared/alerts_list.dart';

class CaregiverHomeScreen extends StatelessWidget {
  const CaregiverHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final patients = state.patients;
    final fmt = DateFormat('yyyy-MM-dd HH:mm');

    return Scaffold(
      appBar: AppBar(
        title: const Text('متابعة الأسرة'),
        actions: [
          IconButton(
            tooltip: 'تحديث من السحابة',
            onPressed: () => state.refreshFromCloud(),
            icon: const Icon(Icons.cloud_download),
          ),
          IconButton(
            onPressed: () => state.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: patients.isEmpty
          ? const Center(child: Text('لا يوجد مرضى مرتبطون'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ...patients.map((p) {
                  final assessment = state.monitoring.latestAssessment;
                  final label = assessment?.label ?? p.currentStatus;
                  return Card(
                    child: ListTile(
                      title: Text(p.name),
                      subtitle: Text(
                        assessment == null
                            ? 'لا توجد قراءات بعد'
                            : 'آخر تحديث: ${fmt.format(assessment.timestamp)}',
                      ),
                      trailing: StatusBadge(label: label),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => _CaregiverDetail(patientId: p.patientId, name: p.name),
                          ),
                        );
                      },
                    ),
                  );
                }),
                const SizedBox(height: 16),
                Text('التنبيهات', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                SizedBox(
                  height: 360,
                  child: AlertsList(
                    alerts: state.monitoring.alerts,
                    onAcknowledge: state.acknowledgeAlert,
                  ),
                ),
              ],
            ),
    );
  }
}

class _CaregiverDetail extends StatelessWidget {
  const _CaregiverDetail({required this.patientId, required this.name});

  final String patientId;
  final String name;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final label = state.monitoring.latestAssessment?.label ?? RiskLabel.stable;
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusBadge(label: label),
            const SizedBox(height: 12),
            Text('معرّف المريض: $patientId'),
            const SizedBox(height: 8),
            const Text('ميزة الموقع مؤجلة للإصدارات القادمة حسب نطاق V1.'),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => state.forceHighRiskDemo(),
              icon: const Icon(Icons.notification_important),
              label: const Text('اختبار تنبيه خطر'),
            ),
          ],
        ),
      ),
    );
  }
}
