import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../providers/app_state.dart';
import '../../services/background_service.dart';
import '../../services/biometric_service.dart';

/// Screen allowing users (across all roles) to inspect, diagnose, and manage
/// system permissions on Android and other host operating systems.
class DevicePermissionsScreen extends StatefulWidget {
  const DevicePermissionsScreen({super.key});

  @override
  State<DevicePermissionsScreen> createState() =>
      _DevicePermissionsScreenState();
}

class _DevicePermissionsScreenState extends State<DevicePermissionsScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  LocationPermission _locationPermission = LocationPermission.denied;
  bool _locationServiceEnabled = false;
  bool _biometricsAvailable = false;
  // Read from the OS (was a constant «enabled», which hid a refusal). True
  // where the OS gives no answer, so nothing false is shown as a failure.
  bool _notificationsAllowed = true;
  bool _exactAlarms = true;
  bool _hasGps = true;
  final _biometrics = BiometricService();
  final _background = BackgroundService();
  bool _batteryExempt = true;
  bool _fullScreenAllowed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAllPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Returning from a system settings page: show the real, updated state.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) _checkAllPermissions();
  }

  Future<void> _checkAllPermissions() async {
    setState(() => _loading = true);
    try {
      final locPerm = await Geolocator.checkPermission();
      final locEnabled = await Geolocator.isLocationServiceEnabled();
      final bioAvail = await _biometrics.isAvailable;
      final batteryExempt = await _background.isIgnoringBatteryOptimizations();
      final fullScreen = await _background.canUseFullScreenIntent();
      final hasGps = await _background.hasGpsHardware();
      if (!mounted) return;
      final notifications = context.read<AppState>().notifications;
      final notifAllowed = await notifications.notificationsEnabled();
      final exact = await notifications.canScheduleExact();

      if (mounted) {
        setState(() {
          _locationPermission = locPerm;
          _locationServiceEnabled = locEnabled;
          _biometricsAvailable = bioAvail;
          _batteryExempt = batteryExempt;
          _fullScreenAllowed = fullScreen;
          _hasGps = hasGps;
          _notificationsAllowed = notifAllowed ?? true;
          _exactAlarms = exact ?? true;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _requestLocation() async {
    try {
      final res = await Geolocator.requestPermission();
      if (mounted) {
        setState(() => _locationPermission = res);
        if (res == LocationPermission.deniedForever) {
          _promptOpenSettings('الموقع الجغرافي');
        }
      }
    } catch (_) {}
  }

  Future<void> _promptOpenSettings(String permissionName) async {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          ar ? 'الإذن معطل في النظام' : 'Permission Disabled in System',
        ),
        content: Text(
          ar
              ? 'إذن «$permissionName» تم رفضه في إعدادات الهاتف. يتطلب تفعيله فتح إعدادات التطبيق في نظام أندرويد.'
              : '$permissionName permission is disabled. Enabling it requires opening application settings in Android.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.settings, size: 18),
            label: Text(ar ? 'فتح الإعدادات' : 'Open Settings'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await Geolocator.openAppSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final theme = Theme.of(context);

    final isLocationGranted =
        _locationPermission == LocationPermission.always ||
        _locationPermission == LocationPermission.whileInUse;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          ar ? 'صلاحيات وأذونات النظام' : 'System & Device Permissions',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: ar ? 'إعادة الفحص' : 'Refresh Check',
            onPressed: _checkAllPermissions,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Gap.md),
              children: [
                // Header Info Card
                Card(
                  elevation: 0,
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.2,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.security_outlined,
                          color: theme.colorScheme.primary,
                          size: 32,
                        ),
                        Gap.hMd,
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ar
                                    ? 'أذونات حماية المريض وسلامته'
                                    : 'Patient Safety & Protection Permissions',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Gap.vXs,
                              Text(
                                ar
                                    ? 'يعتمد النظام في حالات الطوارئ والنوبات على هذه الصلاحيات لإنقاذ المريض، وإرسال موقعه، وإيقاظ المرافقين في الوقت المناسب.'
                                    : 'In emergency cases and seizures, the system relies on these permissions to rescue the patient, send location, and wake caregivers.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Gap.vLg,

                // Permission 1: Location & GPS
                _PermissionTile(
                  icon: Icons.my_location_rounded,
                  tone: AccentTone.blue,
                  title: ar
                      ? 'الموقع الجغرافي الدقيق (GPS / GNSS)'
                      : 'Precise Location (GPS / GNSS)',
                  subtitle: ar
                      ? 'لالتقاط إحداثيات المريض تلقائياً عند النوبة أو طلب الاستغاثة SOS وإرسالها لجهات الطوارئ.'
                      : 'To automatically capture patient coordinates during a seizure or SOS and dispatch to emergency contacts.',
                  statusLabel: isLocationGranted
                      ? (_locationServiceEnabled
                            ? (ar ? 'ممنوح ومفعل' : 'Granted & Active')
                            : (ar
                                  ? 'الموقع معطل في الجهاز'
                                  : 'Location Service Off'))
                      : (ar ? 'مطلوب للمراقبة' : 'Required'),
                  isGranted: isLocationGranted && _locationServiceEnabled,
                  onAction: isLocationGranted
                      ? (_locationServiceEnabled
                            ? null
                            : () => Geolocator.openLocationSettings())
                      : _requestLocation,
                  actionLabel: isLocationGranted
                      ? (_locationServiceEnabled
                            ? null
                            : (ar ? 'تشغيل GPS' : 'Turn on GPS'))
                      : (ar ? 'منح الإذن' : 'Grant Permission'),
                ),

                Gap.vMd,

                // Permission 2: Notifications
                _PermissionTile(
                  icon: Icons.notification_important_rounded,
                  tone: AccentTone.orange,
                  title: ar
                      ? 'إشعارات وتنبيهات الطوارئ'
                      : 'Emergency Notifications',
                  subtitle: ar
                      ? 'لإيقاظك وتحذيرك قبل حدوث النوبة (Preictal Warning) لتتخذ وضعية الأمان والاستلقاء.'
                      : 'To alert and wake you before seizure onset so you can assume a safe position.',
                  statusLabel: _notificationsAllowed
                      ? (ar ? 'مفعلة للحماية' : 'Enabled for Safety')
                      : (ar ? 'معطلة' : 'Disabled'),
                  isGranted: _notificationsAllowed,
                  onAction: () => Geolocator.openAppSettings(),
                  actionLabel: ar
                      ? 'إعدادات الإشعارات'
                      : 'Notification Settings',
                ),

                if (!_hasGps) ...[
                  Gap.vMd,
                  _PermissionTile(
                    icon: Icons.satellite_alt_outlined,
                    tone: AccentTone.orange,
                    title: ar ? 'لا توجد شريحة GPS' : 'No GPS receiver',
                    subtitle: ar
                        ? 'هاتفك لا يحتوي شريحة GPS. دون إنترنت لن يُرسَل موقعك في الطوارئ؛ أضف «العنوان المعتاد» في البطاقة الطبية ليصل مع رسالة الاستغاثة.'
                        : 'This phone has no GPS receiver. Without internet your location cannot be sent in an emergency; add a «usual address» to the medical card so it goes with the SOS message.',
                    statusLabel: ar ? 'غير متاح' : 'Not available',
                    isGranted: false,
                    onAction: null,
                  ),
                ],
                if (!_exactAlarms) ...[
                  Gap.vMd,
                  _PermissionTile(
                    icon: Icons.alarm_on_outlined,
                    tone: AccentTone.blue,
                    title: ar
                        ? 'تذكير الدواء في وقته الدقيق'
                        : 'Medication reminders on the minute',
                    subtitle: ar
                        ? 'بدونه قد يتأخر تذكير الجرعة بضع دقائق لأن النظام يجمّع المنبهات لتوفير البطارية.'
                        : 'Without it a dose reminder may arrive a few minutes late, because the system batches alarms to save battery.',
                    statusLabel: ar ? 'تقريبي' : 'Approximate',
                    isGranted: false,
                    onAction: () => context
                        .read<AppState>()
                        .notifications
                        .requestExactAlarms(),
                    actionLabel: ar ? 'السماح' : 'Allow',
                  ),
                ],

                if (_background.supported) ...[
                  Gap.vMd,
                  _PermissionTile(
                    icon: Icons.lock_clock_outlined,
                    tone: AccentTone.red,
                    title: ar
                        ? 'التنبيه فوق شاشة القفل'
                        : 'Alerts over the lock screen',
                    subtitle: ar
                        ? 'يفتح شاشة تنبيه النوبة فوراً حتى والهاتف مقفل. إن رُفض يظهر التنبيه كإشعار عادي فقط.'
                        : 'Opens the seizure alert immediately even when the phone is locked. If denied, it appears only as a normal notification.',
                    statusLabel: _fullScreenAllowed
                        ? (ar ? 'مسموح' : 'Allowed')
                        : (ar ? 'غير مسموح' : 'Not allowed'),
                    isGranted: _fullScreenAllowed,
                    onAction: _fullScreenAllowed
                        ? null
                        : () async {
                            await _background.openFullScreenIntentSettings();
                          },
                    actionLabel: _fullScreenAllowed
                        ? null
                        : (ar ? 'السماح' : 'Allow'),
                  ),
                  Gap.vMd,
                  _PermissionTile(
                    icon: Icons.battery_saver_outlined,
                    tone: AccentTone.indigo,
                    title: ar
                        ? 'الاستثناء من توفير البطارية'
                        : 'Battery optimization exemption',
                    subtitle: ar
                        ? 'كي لا يوقف النظام الرصد في الخلفية أو منبهات الدواء عند إطفاء الشاشة.'
                        : 'So the system does not stop background monitoring or medication alarms when the screen is off.',
                    statusLabel: _batteryExempt
                        ? (ar ? 'مستثنى' : 'Exempt')
                        : (ar ? 'غير مستثنى' : 'Not exempt'),
                    isGranted: _batteryExempt,
                    onAction: _batteryExempt
                        ? null
                        : () async {
                            await _background
                                .requestIgnoreBatteryOptimizations();
                          },
                    actionLabel: _batteryExempt
                        ? null
                        : (ar ? 'استثناء التطبيق' : 'Exempt the app'),
                  ),
                ],

                Gap.vMd,

                // Permission 3: Bluetooth & Wearable Sensors
                _PermissionTile(
                  icon: Icons.sensors_rounded,
                  tone: AccentTone.green,
                  title: ar
                      ? 'المستشعرات وأجهزة الارتداء (Headband)'
                      : 'Sensors & Wearable Headband',
                  // Honest: this build has no direct Bluetooth link, so there
                  // is no permission to grant and nothing «integrated».
                  subtitle: ar
                      ? 'لا يتصل هذا الإصدار برباط الرأس عبر Bluetooth مباشرة؛ تصل الإشارات من خادم الجهاز أو من المحاكي، فلا يلزم إذن هنا.'
                      : 'This build has no direct Bluetooth link to the headband; signals come from the device server or the simulator, so no permission is needed here.',
                  statusLabel: ar ? 'لا يلزم إذن' : 'No permission needed',
                  isGranted: true,
                  onAction: null,
                ),

                Gap.vMd,

                // Permission 4: Biometrics & Idle Security
                _PermissionTile(
                  icon: Icons.fingerprint_rounded,
                  tone: AccentTone.indigo,
                  title: ar
                      ? 'القياسات الحيوية وبصمة الجهاز'
                      : 'Biometrics & Device Passcode',
                  subtitle: ar
                      ? 'لقفل الخمول التلقائي وحماية السجلات الطبية والبيانات الحساسة من المتطفلين.'
                      : 'For automated idle lock and protecting clinical records from unauthorized local access.',
                  statusLabel: _biometricsAvailable
                      ? (ar ? 'مدعوم في الجهاز' : 'Hardware Supported')
                      : (ar ? 'غير مدعوم عتادياً' : 'No Hardware Sensor'),
                  isGranted: _biometricsAvailable,
                  onAction: null,
                ),

                Gap.vXl,

                // Open System Settings Button
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () => Geolocator.openAppSettings(),
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(
                    ar
                        ? 'فتح إعدادات التطبيق في نظام التشغيل'
                        : 'Open App Settings in Operating System',
                  ),
                ),
                Gap.vSm,
                Text(
                  ar
                      ? 'ملاحظة: يمكنك في أي وقت تعديل أو إلغاء أي إذن من لوحة إعدادات النظام مباشرة.'
                      : 'Note: You can review or adjust any permission directly in system settings at any time.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
    required this.statusLabel,
    required this.isGranted,
    this.onAction,
    this.actionLabel,
  });

  final IconData icon;
  final AccentTone tone;
  final String title;
  final String subtitle;
  final String statusLabel;
  final bool isGranted;
  final VoidCallback? onAction;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.accent(context, tone);
    // Status colours from the tokens: legible in light and dark themes.
    final ok = AppColors.accent(context, AccentTone.green).foreground;
    final warn = AppColors.accent(context, AccentTone.orange).foreground;

    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isGranted
              ? ok.withValues(alpha: 0.3)
              : warn.withValues(alpha: 0.4),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: c.container,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: c.foreground, size: 24),
              ),
              Gap.hMd,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          isGranted
                              ? Icons.check_circle_rounded
                              : Icons.warning_amber_rounded,
                          size: 14,
                          color: isGranted ? ok : warn,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isGranted ? ok : warn,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          Gap.vSm,
          Padding(
            // Directional: aligns under the title in RTL and LTR alike.
            padding: const EdgeInsetsDirectional.only(start: 52),
            child: Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ),
          if (onAction != null && actionLabel != null) ...[
            Gap.vSm,
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, A11y.minTouchTarget),
                ),
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
