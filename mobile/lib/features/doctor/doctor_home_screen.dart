import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../services/report_service.dart';
import '../../widgets/metrics_panel.dart';
import '../../widgets/prediction_history_view.dart';
import '../../widgets/signal_chart.dart';
import '../../widgets/status_badge.dart';
import '../shared/alerts_list.dart';

class DoctorHomeScreen extends StatefulWidget {
  const DoctorHomeScreen({super.key});

  @override
  State<DoctorHomeScreen> createState() => _DoctorHomeScreenState();
}

class _DoctorHomeScreenState extends State<DoctorHomeScreen> {
  final _reports = ReportService();
  String? _exportMessage;

  Future<void> _exportPdf() async {
    final state = context.read<AppState>();
    final patients = state.patients;
    if (patients.isEmpty) return;
    final patient = patients.first;
    final assessments = await state.db.assessmentsFor(patient.patientId);
    final alerts = await state.db.alertsFor(patient.patientId);
    final doc = await _reports.toPdf(
      patient: patient,
      assessments: assessments,
      alerts: alerts,
    );
    await Printing.layoutPdf(onLayout: (_) => doc.save());
    setState(() => _exportMessage = 'تم تجهيز تقرير PDF');
  }

  Future<void> _exportCsv() async {
    final state = context.read<AppState>();
    final patients = state.patients;
    if (patients.isEmpty) return;
    final patient = patients.first;
    final assessments = await state.db.assessmentsFor(patient.patientId);
    final alerts = await state.db.alertsFor(patient.patientId);
    final csv = _reports.toCsv(
      patient: patient,
      assessments: assessments,
      alerts: alerts,
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تقرير CSV'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(csv)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
        ],
      ),
    );
    setState(() => _exportMessage = 'تم إنشاء CSV');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final patients = state.patients;
    final reading = state.monitoring.latestReading;
    final assessment = state.monitoring.latestAssessment;
    final fmt = DateFormat('HH:mm');

    return Scaffold(
      appBar: AppBar(
        title: const Text('لوحة الطبيب'),
        actions: [
          IconButton(
            tooltip: 'تحديث من السحابة',
            onPressed: () => state.refreshFromCloud(),
            icon: const Icon(Icons.cloud_download),
          ),
          IconButton(
            tooltip: 'تصدير PDF',
            onPressed: _exportPdf,
            icon: const Icon(Icons.picture_as_pdf),
          ),
          IconButton(
            tooltip: 'تصدير CSV',
            onPressed: _exportCsv,
            icon: const Icon(Icons.table_chart),
          ),
          IconButton(
            onPressed: () => state.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('المرضى', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          ...patients.map(
            (p) => Card(
              child: ListTile(
                title: Text(p.name),
                subtitle: Text('${p.diagnosis} · أدوية: ${p.medications.join(", ")}'),
                trailing: StatusBadge(label: assessment?.label ?? p.currentStatus),
              ),
            ),
          ),
          if (_exportMessage != null) ...[
            const SizedBox(height: 8),
            Text(_exportMessage!, style: TextStyle(color: Colors.green.shade700)),
          ],
          const SizedBox(height: 16),
          Text('الرسوم التفصيلية', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (reading != null) ...[
            Text(
              'آخر قراءة ${fmt.format(reading.timestamp)} · HR ${reading.hr.toStringAsFixed(0)}',
            ),
            const SizedBox(height: 8),
            SignalChart(title: 'EEG', values: reading.eeg, color: const Color(0xFF0B6E4F)),
            SignalChart(title: 'ECG', values: reading.ecg, color: const Color(0xFF1B4965)),
            SignalChart(title: 'Motion', values: reading.motion, color: const Color(0xFF9A3412)),
          ] else
            const Text('لا توجد قراءات بعد — شغّل المحاكاة من حساب المريض أو انتظر الدقيقة التالية.'),
          const SizedBox(height: 16),
          Text('مقارنة التقييمات الأخيرة', style: Theme.of(context).textTheme.titleMedium),
          FutureBuilder<List<RiskAssessment>>(
            future: patients.isEmpty
                ? Future.value(<RiskAssessment>[])
                : state.db.assessmentsFor(patients.first.patientId, limit: 8),
            builder: (context, snap) {
              final items = snap.data ?? <RiskAssessment>[];
              if (items.isEmpty) return const Text('لا توجد تقييمات');
              return Column(
                children: items
                    .map(
                      (a) => ListTile(
                        dense: true,
                        title: Text(a.label.labelAr),
                        subtitle: Text(fmt.format(a.timestamp)),
                        trailing: Text('${(a.confidence * 100).toStringAsFixed(0)}%'),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 16),
          Text('أداء النماذج (تقييم غير متصل)',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const MetricsPanel(),
          const SizedBox(height: 16),
          Text('سجل أحداث التنبؤ (مهلات محقّقة)',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (patients.isNotEmpty)
            PredictionHistoryView(patientId: patients.first.patientId)
          else
            const Text('لا يوجد مريض محدد.'),
          const SizedBox(height: 16),
          Text('التنبيهات', style: Theme.of(context).textTheme.titleLarge),
          SizedBox(
            height: 280,
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
