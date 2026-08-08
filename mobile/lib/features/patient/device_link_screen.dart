import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../providers/app_state.dart';
import '../../services/monitoring_service.dart';

class DeviceLinkScreen extends StatelessWidget {
  const DeviceLinkScreen({super.key});

  String _sourceTitle(SignalSource s) => switch (s) {
        SignalSource.headDevice => 'جهاز الرأس',
        SignalSource.dataset => 'Dataset (بدون جهاز)',
        SignalSource.simulator => 'محاكاة برمجية',
      };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final m = state.monitoring;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('مصدر الإشارات الحيوية', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'حالياً لا يوجد جهاز حقيقي. يمكن التشغيل من Dataset أو المحاكاة، '
          'وعند توفر الجهاز يُفعّل وضع «جهاز الرأس» بنفس المسار.',
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.sensors),
            title: Text('المصدر الحالي: ${_sourceTitle(m.source)}'),
            subtitle: Text(
              m.source == SignalSource.headDevice
                  ? (m.deviceConnected
                      ? 'متصل · ${m.deviceId ?? "-"} · ${m.deviceBuffered} عينة'
                      : 'بانتظار بيانات الجهاز...')
                  : m.source == SignalSource.dataset
                      ? 'قراءة نوافذ موسومة من قاعدة بيانات الإشارات ثم تحليلها بالنموذج'
                      : 'توليد إشارات داخل التطبيق للتجربة السريعة',
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: state.useDataset,
          icon: const Icon(Icons.storage),
          label: const Text('تشغيل من Dataset (موصى به الآن)'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: state.useSimulator,
          icon: const Icon(Icons.auto_graph),
          label: const Text('محاكاة برمجية'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: state.useHeadDevice,
          icon: const Icon(Icons.headset_mic),
          label: const Text('استقبال من الجهاز (لاحقاً / محاكي)'),
        ),
        const SizedBox(height: 20),
        Text('إعدادات السيرفر', style: Theme.of(context).textTheme.titleMedium),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('API'),
          subtitle: Text(AppConfig.apiBaseUrl),
          trailing: IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: AppConfig.apiBaseUrl));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تم النسخ')),
                );
              }
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('patient_id'),
          subtitle: Text(state.auth.currentUser?.uid ?? '-'),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6F7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            'مسار MVP بدون جهاز:\n'
            '1) شغّل السيرفر\n'
            '2) من هنا اختر Dataset\n'
            '3) راقب الحالة والتنبيه والسجل\n'
            '4) حساب الأسرة/الطبيب يرى التنبيهات عبر التخزين السحابي المبسط على السيرفر',
          ),
        ),
      ],
    );
  }
}
