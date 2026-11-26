import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/errors/failure.dart';
import '../../core/router/route_names.dart';
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
              title: ar
                  ? 'محرك الإشارات واختبار التنبؤ'
                  : 'Signal Engine & Prediction Testing',
              icon: Icons.science_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    ar
                        ? 'يعمل النظام افتراضياً بنمط تدفق البيانات السريرية المعتمدة (CHB-MIT) مع نموذج الذكاء الاصطناعي، مع التحول التلقائي للمحاكاة المحلية السريعة عند انقطاع الاتصال.'
                        : 'System operates via clinical EEG dataset replay with deep learning, automatically falling back to local simulation when disconnected.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.of(
                        context,
                        RiskView.safe,
                      ).solid,
                      foregroundColor: AppColors.of(
                        context,
                        RiskView.safe,
                      ).onSolid,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () =>
                        Navigator.pushNamed(context, Routes.patientSimulator),
                    icon: const Icon(Icons.tune, size: 20),
                    label: Text(
                      ar
                          ? 'فتح محاكي الإشارات واختبار النوبات (4 مراحل)'
                          : 'Open Signal Simulator (4 Phases)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
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
                          ? AppColors.accent(
                              context,
                              AccentTone.green,
                            ).container
                          : AppColors.accent(
                              context,
                              AccentTone.orange,
                            ).container,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      app.apiOnline
                          ? Icons.verified_user_outlined
                          : Icons.cloud_off_outlined,
                      color: app.apiOnline
                          ? AppColors.of(context, RiskView.safe).foreground
                          : AppColors.of(context, RiskView.caution).foreground,
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
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
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
                                ? AppColors.of(
                                    context,
                                    RiskView.safe,
                                  ).foreground
                                : AppColors.of(
                                    context,
                                    RiskView.caution,
                                  ).foreground,
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
