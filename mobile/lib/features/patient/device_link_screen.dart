import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/errors/failure.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import '../../services/eeg_hardware_device.dart';
import '../../services/monitoring_service.dart';

class DeviceLinkScreen extends StatefulWidget {
  const DeviceLinkScreen({super.key});
  @override
  State<DeviceLinkScreen> createState() => _DeviceLinkScreenState();
}

class _DeviceLinkScreenState extends State<DeviceLinkScreen> {
  Future<Map<String, dynamic>>? _contract;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _loadContract();
  }

  void _loadContract() {
    final app = context.read<AppState>();
    _contract = _fetchContract(app);
  }

  Future<Map<String, dynamic>> _fetchContract(AppState app) async {
    try {
      return await app.api.getObject('/device/contract');
    } catch (_) {
      return const {
        'version': 1,
        'intended_use': 'research_and_simulation_only',
        'sample_rate_hz': 256,
        'eeg_channels': 1,
        'signal_units': 'normalized_demo',
        'max_batch_samples': 512,
        'analysis_window_samples': 262,
        'channels': ['eeg', 'ecg', 'motion', 'hr'],
        'physical_device_compatible': false,
        'requirements_for_physical_device': [
          'Document sensor, electrode montage and reference, units and calibration',
          'Implement validated sampling, timestamps, signal quality and missing-channel handling',
          'Match the deployed model preprocessing and training input contract',
          'Validate on independent continuous annotated patient recordings',
        ],
      };
    }
  }

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
    final monitor = app.monitoring;
    final connected =
        monitor.source == SignalSource.headDevice && monitor.deviceConnected;
    return Scaffold(
      appBar: AppBar(
        title: Text(ar ? 'الجهاز ومصدر البيانات' : 'Device & data source'),
      ),
      body: ResponsiveContent(
        maxWidth: 760,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SectionCard(
              title: ar ? 'حالة المصدر' : 'Source status',
              icon: Icons.sensors,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    connected
                        ? (ar
                              ? 'تصل بيانات الجهاز عبر الخادم'
                              : 'Device data is arriving through the server')
                        : (ar
                              ? 'لا يوجد اتصال جهاز مؤكّد'
                              : 'No confirmed device connection'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (monitor.deviceId != null)
                    Text('${ar ? 'الجهاز' : 'Device'}: ${monitor.deviceId}'),
                  FutureBuilder<DeviceDiagnostics?>(
                    future: monitor.getDiagnostics(),
                    builder: (context, diagSnapshot) {
                      final diag = diagSnapshot.data;
                      if (diag == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 4),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            Chip(
                              avatar: Icon(
                                diag.isSimulated
                                    ? Icons.memory_outlined
                                    : Icons.bluetooth_connected,
                                size: 16,
                              ),
                              label: Text(
                                diag.isSimulated
                                    ? (ar ? 'محاكي برمجي' : 'Software Emulator')
                                    : (ar ? 'جهاز حقيقي' : 'Physical Device'),
                              ),
                            ),
                            Chip(
                              label: Text(
                                '${diag.sampleRateHz} Hz • ${diag.samplesBuffered} ${ar ? 'عيّنة' : 'samples'}',
                              ),
                            ),
                            Chip(label: Text(diag.transportMode)),
                          ],
                        ),
                      );
                    },
                  ),
                  Text(
                    ar
                        ? 'اختيار المصدر لا يعني اقتران جهاز. هذا الإصدار يستقبل بيانات الجهاز من الخادم، ولا يوفر ربط EEG مباشرًا بالهاتف.'
                        : 'Selecting a source does not pair a device. This build receives device data through the server and has no direct EEG connection to the phone.',
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _select(SignalSource.headDevice),
                    icon: const Icon(Icons.sensors),
                    label: Text(
                      ar
                          ? 'استخدام تدفق الجهاز من الخادم'
                          : 'Use the server device stream',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SectionCard(
              title: ar ? 'متطلبات البيانات' : 'Data requirements',
              icon: Icons.rule_outlined,
              child: FutureBuilder<Map<String, dynamic>>(
                future: _contract,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const LinearProgressIndicator();
                  }
                  if (snapshot.hasError) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ar
                              ? 'تعذر تحميل مواصفات الخادم.'
                              : 'Unable to load the server contract.',
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            _loadContract();
                          }),
                          child: Text(ar ? 'إعادة المحاولة' : 'Retry'),
                        ),
                      ],
                    );
                  }
                  final data = snapshot.data ?? {};
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LabeledValue(
                        label: ar ? 'تردد العينات (Hz)' : 'Sample rate (Hz)',
                        value: '${data['sample_rate_hz'] ?? '—'}',
                      ),
                      LabeledValue(
                        label: ar ? 'قنوات EEG' : 'EEG channels',
                        value: '${data['eeg_channels'] ?? '—'}',
                      ),
                      LabeledValue(
                        label: ar
                            ? 'عينات نافذة التحليل'
                            : 'Analysis window samples',
                        value: '${data['analysis_window_samples'] ?? '—'}',
                      ),
                      LabeledValue(
                        label: ar ? 'القنوات المدعومة' : 'Channels',
                        value:
                            (data['channels'] as List?)?.join(', ') ??
                            'eeg, ecg, motion, hr',
                      ),
                      LabeledValue(
                        label: ar ? 'وحدات الإشارة' : 'Signal units',
                        value: '${data['signal_units'] ?? 'normalized_demo'}',
                      ),
                      const SizedBox(height: 12),
                      InfoNote(
                        text: data['physical_device_compatible'] == true
                            ? (ar
                                  ? 'تحقق من مطابقة مواصفات جهازك قبل الاستخدام.'
                                  : 'Verify that your device matches the contract before use.')
                            : (ar
                                  ? 'العقد الحالي بحثي وتجريبي؛ لا يؤكد توافق جهاز طبي فعلي.'
                                  : 'The current contract is for research and simulation; physical medical-device compatibility is unconfirmed.'),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            SectionCard(
              title: ar ? 'محاكاة الإشارات والاختبار' : 'Signal Simulation & Testing',
              icon: Icons.science_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    ar
                        ? 'توليد إشارات EEG حيوية واختبار استجابة النظام وتصعيد التنبيهات في غياب جهاز طبي مقترن.'
                        : 'Generate vital EEG signals and test system alert response when no physical device is paired.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _select(SignalSource.simulator),
                          icon: Icon(
                            monitor.source == SignalSource.simulator
                                ? Icons.check_circle
                                : Icons.play_arrow,
                            color: monitor.source == SignalSource.simulator
                                ? const Color(0xFF0F7A4D)
                                : null,
                          ),
                          label: Text(
                            monitor.source == SignalSource.simulator
                                ? (ar ? 'المحاكي نشط' : 'Simulator Active')
                                : (ar ? 'تشغيل المحاكي' : 'Start Simulator'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _select(SignalSource.dataset),
                          icon: Icon(
                            monitor.source == SignalSource.dataset
                                ? Icons.check_circle
                                : Icons.dataset_outlined,
                            color: monitor.source == SignalSource.dataset
                                ? const Color(0xFF0F7A4D)
                                : null,
                          ),
                          label: Text(
                            monitor.source == SignalSource.dataset
                                ? (ar ? 'البيانات نشطة' : 'Dataset Active')
                                : (ar ? 'بيانات مسجلة' : 'Recorded Dataset'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFFE4EDF7),
                  width: 1.2,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x06000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: app.apiOnline
                          ? const Color(0xFFE8F5E9)
                          : const Color(0xFFFFF3E0),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      app.apiOnline
                          ? Icons.verified_user_outlined
                          : Icons.cloud_off_outlined,
                      color: app.apiOnline
                          ? const Color(0xFF0F7A4D)
                          : const Color(0xFF9A6400),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ar
                              ? 'حالة المعالجة والاتصال'
                              : 'Processing & Connection Status',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF64748B),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          app.apiOnline
                              ? (ar
                                    ? 'متصل بالخدمة السحابية الآمنة'
                                    : 'Connected to Secure Cloud Service')
                              : (ar
                                    ? 'وضع المعالجة المحلية (دون إنترنت)'
                                    : 'Local Processing Mode (Offline)'),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: app.apiOnline
                                ? const Color(0xFF0F7A4D)
                                : const Color(0xFF9A6400),
                          ),
                        ),
                      ],
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
