import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../core/enums.dart';
import '../../providers/app_state.dart';
import '../../services/monitoring_service.dart';
import '../../widgets/lead_time_card.dart';
import '../../widgets/prediction_gauge.dart';
import '../../widgets/signal_chart.dart';
import '../../widgets/status_badge.dart';
import '../shared/alerts_list.dart';
import '../shared/medical_record_view.dart';
import 'device_link_screen.dart';
import 'medication_screen.dart';

class PatientHomeScreen extends StatelessWidget {
  const PatientHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.auth.currentUser!;
    final assessment = state.monitoring.latestAssessment;
    final reading = state.monitoring.latestReading;
    final label = assessment?.label ?? RiskLabel.stable;
    final fmt = DateFormat('HH:mm:ss');
    final fromDevice = state.monitoring.source == SignalSource.headDevice;

    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('لوحة المريض'),
          actions: [
            if (!fromDevice)
              IconButton(
                tooltip: 'محاكاة خطر مرتفع',
                onPressed: () => state.forceHighRiskDemo(),
                icon: const Icon(Icons.warning_amber_rounded),
              ),
            _HorizonSettingsButton(state: state),
            IconButton(
              onPressed: () => state.signOut(),
              icon: const Icon(Icons.logout),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'الرئيسية'),
              Tab(text: 'الجهاز'),
              Tab(text: 'التنبيهات'),
              Tab(text: 'السجل'),
              Tab(text: 'الدواء'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SosCard(state: state),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        user.name,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    StatusBadge(label: label),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  assessment == null
                      ? 'بانتظار أول قراءة...'
                      : 'آخر تحديث: ${fmt.format(assessment.timestamp)} · ثقة ${(assessment.confidence * 100).toStringAsFixed(0)}%',
                ),
                const SizedBox(height: 4),
                Text(
                  fromDevice
                      ? (state.monitoring.deviceConnected
                          ? 'مصدر البيانات: جهاز الرأس (متصل)'
                          : 'مصدر البيانات: جهاز الرأس (بانتظار الإرسال)')
                      : (state.apiOnline
                          ? 'مصدر البيانات: محاكاة + خادم التحليل'
                          : 'مصدر البيانات: محاكاة محلية دون اتصال'),
                  style: TextStyle(
                    color: fromDevice
                        ? (state.monitoring.deviceConnected
                            ? Colors.teal.shade700
                            : Colors.orange.shade800)
                        : (state.apiOnline ? Colors.green.shade700 : Colors.orange.shade800),
                  ),
                ),
                if (state.apiOnline && state.activeEngine != null) ...[
                  const SizedBox(height: 6),
                  _EngineChip(engine: state.activeEngine!),
                ],
                const SizedBox(height: 16),
                if (state.monitoring.latestPrediction != null) ...[
                  PredictionGauge(
                    prediction: state.monitoring.latestPrediction!,
                  ),
                  const SizedBox(height: 12),
                  LeadTimeCard(
                    prediction: state.monitoring.latestPrediction!,
                  ),
                  const SizedBox(height: 16),
                ],
                if (reading != null) ...[
                  Text(
                    'معدل النبض: ${reading.hr.toStringAsFixed(0)} bpm',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  SignalChart(title: 'EEG', values: reading.eeg, color: const Color(0xFF0B6E4F)),
                  const SizedBox(height: 12),
                  SignalChart(title: 'ECG', values: reading.ecg, color: const Color(0xFF1B4965)),
                  const SizedBox(height: 12),
                  SignalChart(
                    title: 'الحركة',
                    values: reading.motion,
                    color: const Color(0xFF9A3412),
                  ),
                ],
              ],
            ),
            const DeviceLinkScreen(),
            AlertsList(
              alerts: state.monitoring.alerts,
              onAcknowledge: state.acknowledgeAlert,
            ),
            MedicalRecordView(patientId: user.uid),
            MedicationScreen(patientId: user.uid),
          ],
        ),
      ),
    );
  }
}

/// Prominent, always-visible SOS button on the patient's home tab. Fires a
/// best-effort GPS-tagged critical alert to caregivers/doctors; still sends if
/// location is unavailable. A short confirm guards against accidental taps.
class _SosCard extends StatelessWidget {
  const _SosCard({required this.state});

  final AppState state;

  Future<void> _confirmAndSend(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إرسال استغاثة؟'),
        content: const Text(
          'سيتم إبلاغ مقدّم الرعاية والطبيب فوراً مع موقعك إن كان متاحاً.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB42318)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إرسال'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.triggerSos();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إرسال الاستغاثة')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFB42318),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: state.sosInProgress ? null : () => _confirmAndSend(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              const Icon(Icons.sos, color: Colors.white, size: 28),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'استغاثة SOS — طلب مساعدة فورية',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              if (state.sosInProgress)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              else
                const Icon(Icons.chevron_left, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small badge showing which backend inference engine is live, so the deep
/// CNN-LSTM model's presence is visible in the UI (and during the defense).
class _EngineChip extends StatelessWidget {
  const _EngineChip({required this.engine});

  final String engine;

  @override
  Widget build(BuildContext context) {
    final (labelAr, color, icon) = switch (engine) {
      'cnn_lstm_fusion' => ('نموذج تعلّم عميق CNN-LSTM', Colors.indigo, Icons.psychology),
      'sklearn' => ('نموذج تعلّم آلي (احتياطي)', Colors.blueGrey, Icons.hub),
      _ => ('قواعد استدلال (احتياطي)', Colors.brown, Icons.rule),
    };
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(
              'محرك التحليل: $labelAr',
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// App-bar action to configure the seizure-prediction horizon (SPH, #21).
/// Opens a slider dialog (5–30 min per the spec); the chosen value is persisted
/// via `shared_preferences` and applied to the offline forecast heuristic. The
/// online backend uses PREICTAL_HORIZON_MIN and the simulator uses --horizon-min,
/// so the dialog states plainly that this setting governs the offline/simulation
/// forecast — keeping the demo honest about what changes where.
class _HorizonSettingsButton extends StatelessWidget {
  const _HorizonSettingsButton({required this.state});

  final AppState state;

  Future<void> _open(BuildContext context) async {
    var value = state.preictalHorizonMin;
    final chosen = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('أفق التنبؤ بالنوبة (SPH)'),
        content: StatefulBuilder(
          builder: (ctx, setLocal) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'المدة التي يحاول النظام التنبؤ بالنوبة قبلها. تُطبَّق على التنبؤ '
                'دون اتصال والمحاكاة؛ أما الخادم فيستخدم PREICTAL_HORIZON_MIN.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  '${value.toStringAsFixed(0)} دقيقة',
                  style: Theme.of(ctx).textTheme.headlineSmall,
                ),
              ),
              Slider(
                value: value,
                min: AppConfig.minHorizonMin,
                max: AppConfig.maxHorizonMin,
                divisions:
                    (AppConfig.maxHorizonMin - AppConfig.minHorizonMin).round(),
                label: '${value.toStringAsFixed(0)} د',
                onChanged: (v) => setLocal(() => value = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, value),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (chosen != null) {
      await state.setPreictalHorizonMin(chosen);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('أفق التنبؤ: ${chosen.toStringAsFixed(0)} دقيقة')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'إعدادات التنبؤ',
      onPressed: () => _open(context),
      icon: const Icon(Icons.tune),
    );
  }
}
