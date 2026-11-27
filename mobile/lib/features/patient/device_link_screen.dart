import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failure.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import '../../services/eeg_hardware_device.dart';
import '../../services/monitoring_service.dart';

/// «حالة الحساس»: what the patient needs to know about their sensor at a
/// glance — is it connected, is the signal good, when did the last reading
/// arrive, and who is analysing it right now. Source switching and technical
/// diagnostics live in a collapsed «advanced» section.
class DeviceLinkScreen extends StatefulWidget {
  const DeviceLinkScreen({super.key});
  @override
  State<DeviceLinkScreen> createState() => _DeviceLinkScreenState();
}

class _DeviceLinkScreenState extends State<DeviceLinkScreen> {
  bool _busy = false;

  Future<void> _select(SignalSource source) async {
    if (_busy) return;
    setState(() => _busy = true);
    final app = context.read<AppState>();
    try {
      switch (source) {
        case SignalSource.headDevice:
          await app.useHeadDevice();
        case SignalSource.dataset:
          await app.useDataset();
        case SignalSource.simulator:
          await app.useSimulator();
      }
    } catch (error) {
      if (mounted) {
        AppSnack.error(
          context,
          Failure.from(error).message(AppLocalizations.of(context)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l = AppLocalizations.of(context);
    final ar = l.isArabic;
    final m = app.monitoring;
    final reading = m.latestReading;
    final receiving = m.running && m.deviceConnected && reading != null;
    final goodSignal = m.hasUsableAssessment;
    final engine = m.latestAssessment?.features['engine'] as String?;
    final onPhone = engine == 'edge_onnx' || engine == 'edge_multimodal';
    final virtual = m.source == SignalSource.simulator;

    final (RiskView view, IconData icon, String title, String body) = !m.running
        ? (
            RiskView.unknown,
            Icons.sensors_off_outlined,
            ar ? 'المراقبة متوقفة' : 'Monitoring is off',
            ar
                ? 'شغّل المراقبة من الصفحة الرئيسية ليبدأ الحساس بالقراءة.'
                : 'Start monitoring from the home screen to begin reading.',
          )
        : !receiving
        ? (
            RiskView.caution,
            Icons.sensors_off_outlined,
            ar ? 'لا تصل قراءات من الحساس' : 'No readings from the sensor',
            ar
                ? 'تأكد أن الحساس يعمل وقريب من الهاتف. سيُعاد الاتصال تلقائيًا.'
                : 'Make sure the sensor is on and near the phone. It reconnects automatically.',
          )
        : goodSignal
        ? (
            RiskView.safe,
            Icons.sensors,
            ar ? 'الحساس متصل والإشارة جيدة' : 'Sensor connected, good signal',
            ar
                ? 'تصل القراءات باستمرار ويتم تحليلها الآن.'
                : 'Readings are arriving continuously and being analysed.',
          )
        : (
            RiskView.caution,
            Icons.sensors,
            ar ? 'الحساس متصل والإشارة ضعيفة' : 'Sensor connected, weak signal',
            ar
                ? 'عدّل وضع الحساس قليلًا حتى تتحسن الإشارة.'
                : 'Adjust the sensor slightly until the signal improves.',
          );
    final tone = AppColors.of(context, view);

    return Scaffold(
      appBar: AppBar(title: Text(ar ? 'حالة الحساس' : 'Sensor status')),
      body: ResponsiveContent(
        maxWidth: 760,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: tone.container,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, color: tone.foreground, size: 30),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: tone.foreground,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(body, style: TextStyle(color: tone.foreground)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: ar ? 'التفاصيل' : 'Details',
              icon: Icons.info_outline,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LabeledValue(
                    label: ar ? 'آخر قراءة' : 'Last reading',
                    value: reading == null
                        ? '—'
                        : TimeAgo.stamp(reading.timestamp, l),
                  ),
                  LabeledValue(
                    label: ar ? 'نبض القلب' : 'Heart rate',
                    value: reading == null
                        ? '—'
                        : '${reading.hr.round()} ${ar ? 'نبضة/دقيقة' : 'bpm'}',
                  ),
                  LabeledValue(
                    label: ar ? 'يحلّل الإشارات الآن' : 'Analysed by',
                    value: !receiving
                        ? '—'
                        : onPhone
                        ? (ar ? 'هاتفك (دون إنترنت)' : 'Your phone (offline)')
                        : (ar ? 'الخدمة السحابية' : 'Cloud service'),
                  ),
                  LabeledValue(
                    label: ar ? 'نوع الحساس' : 'Sensor type',
                    value: virtual
                        ? (ar
                              ? 'حساس افتراضي (تجريبي)'
                              : 'Virtual sensor (demo)')
                        : m.source == SignalSource.dataset
                        ? (ar ? 'تسجيل سابق' : 'Recorded data')
                        : (ar ? 'جهاز الرأس' : 'Headset'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: ExpansionTile(
                leading: const Icon(Icons.tune),
                title: Text(ar ? 'خيارات متقدمة' : 'Advanced options'),
                subtitle: Text(
                  ar
                      ? 'للتجربة والعرض: مصدر الإشارات والمحاكي'
                      : 'For testing and demos: signal source and simulator',
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  _SourceOption(
                    selected: m.source == SignalSource.simulator,
                    busy: _busy,
                    icon: Icons.memory_outlined,
                    title: ar ? 'الحساس الافتراضي' : 'Virtual sensor',
                    subtitle: ar
                        ? 'يعمل على الهاتف مع الإنترنت ودونه (الافتراضي).'
                        : 'Runs on the phone, online and offline (default).',
                    onTap: () => _select(SignalSource.simulator),
                  ),
                  _SourceOption(
                    selected: m.source == SignalSource.dataset,
                    busy: _busy,
                    icon: Icons.history_outlined,
                    title: ar
                        ? 'تسجيلات سريرية سابقة'
                        : 'Recorded clinical data',
                    subtitle: ar
                        ? 'إعادة عرض تسجيلات EEG من الخادم (يحتاج الإنترنت).'
                        : 'Replays EEG recordings from the server (needs internet).',
                    onTap: () => _select(SignalSource.dataset),
                  ),
                  _SourceOption(
                    selected: m.source == SignalSource.headDevice,
                    busy: _busy,
                    icon: Icons.sensors,
                    title: ar ? 'جهاز الرأس عبر الخادم' : 'Headset via server',
                    subtitle: ar
                        ? 'يستقبل بيانات جهاز حقيقي أو محاكٍ خارجي عند توفره.'
                        : 'Receives a real headset or external simulator when available.',
                    onTap: () => _select(SignalSource.headDevice),
                  ),
                  const SizedBox(height: 8),
                  FutureBuilder<DeviceDiagnostics?>(
                    future: m.getDiagnostics(),
                    builder: (context, snap) {
                      final d = snap.data;
                      if (d == null) return const SizedBox.shrink();
                      return Text(
                        '${d.sampleRateHz} Hz · ${d.samplesBuffered} '
                        '${ar ? 'عيّنة' : 'samples'} · ${d.transportMode}',
                        style: Theme.of(context).textTheme.bodySmall,
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () =>
                        Navigator.pushNamed(context, Routes.patientSimulator),
                    icon: const Icon(Icons.science_outlined),
                    label: Text(
                      ar
                          ? 'لوحة المحاكي وتصعيد الحالة'
                          : 'Simulator & escalation panel',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.selected,
    required this.busy,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final bool busy;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: selected
        ? Icon(
            Icons.check_circle,
            color: AppColors.of(context, RiskView.safe).foreground,
          )
        : null,
    onTap: busy || selected ? null : onTap,
  );
}
