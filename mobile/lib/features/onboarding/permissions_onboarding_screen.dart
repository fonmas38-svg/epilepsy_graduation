import '../../core/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../providers/app_state.dart';

/// Screen displayed on first launch on mobile/Android after the splash animation
/// and before the login screen.
///
/// Explains why permissions are required from a medical, safety, and technical
/// standpoint, giving the patient full confidence and trust.
class PermissionsOnboardingScreen extends StatefulWidget {
  const PermissionsOnboardingScreen({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<PermissionsOnboardingScreen> createState() =>
      _PermissionsOnboardingScreenState();
}

class _PermissionsOnboardingScreenState
    extends State<PermissionsOnboardingScreen> {
  bool _notificationGranted = true;
  bool _locationGranted = false;

  bool get _ar => Localizations.localeOf(context).languageCode == 'ar';
  bool _hasGps = true;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final hasGps = await context.read<AppState>().background.hasGpsHardware();
    if (mounted && !hasGps) setState(() => _hasGps = false);
    if (!mounted) return;
    // The OS answer, not an assumed «enabled» (null where it cannot be read).
    final notif = await context
        .read<AppState>()
        .notifications
        .notificationsEnabled();
    if (mounted && notif != null) setState(() => _notificationGranted = notif);
    try {
      final loc = await Geolocator.checkPermission();
      if (loc == LocationPermission.always ||
          loc == LocationPermission.whileInUse) {
        if (mounted) setState(() => _locationGranted = true);
      }
    } catch (_) {}
  }

  /// The system prompt first; once refused, Android only re-enables it from
  /// the app's settings page.
  Future<void> _requestNotifications() async {
    final notifications = context.read<AppState>().notifications;
    final granted = await notifications.requestNotifications();
    if (granted != true) await Geolocator.openAppSettings();
    final now = await notifications.notificationsEnabled();
    if (mounted && now != null) setState(() => _notificationGranted = now);
  }

  Future<void> _requestLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        final ok = await _promptDialog(
          title: _ar
              ? 'خدمة تحديد الموقع (GPS) مغلقة'
              : 'Location (GPS) is turned off',
          body: _ar
              ? 'خدمة الـ GPS مغلقة في هاتفك. يرجى تفعيل الموقع لتمكين النظام من تحديد مكانك وقت الطوارئ.'
              : 'GPS is off on your phone. Turn on location so the system can find you in an emergency.',
          actionText: _ar ? 'تفعيل الـ GPS' : 'Turn on GPS',
        );
        if (ok == true) {
          await Geolocator.openLocationSettings();
        }
        return;
      }

      final loc = await Geolocator.requestPermission();
      if (loc == LocationPermission.always ||
          loc == LocationPermission.whileInUse) {
        if (mounted) setState(() => _locationGranted = true);
      } else if (loc == LocationPermission.deniedForever) {
        if (!mounted) return;
        final ok = await _promptDialog(
          title: _ar
              ? 'إذن الموقع معطل في إعدادات الهاتف'
              : 'Location is blocked in phone settings',
          body: _ar
              ? 'تم رفض إذن الموقع للتطبيق سابقاً. يرجى فتح إعدادات التطبيق وتفعيل إذن «الموقع» لحمايتك.'
              : 'Location was denied for this app earlier. Open the app settings and allow «Location» for your safety.',
          actionText: _ar ? 'فتح الإعدادات' : 'Open settings',
        );
        if (ok == true) {
          await Geolocator.openAppSettings();
        }
      }
    } catch (_) {}
  }

  Future<bool?> _promptDialog({
    required String title,
    required String body,
    required String actionText,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, textAlign: TextAlign.center),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(actionText),
          ),
        ],
      ),
    );
  }

  Future<void> _finish() async {
    final app = context.read<AppState>();
    await app.setPermissionsOnboardingCompleted();
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ar = _ar;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Gap.lg,
                      vertical: Gap.xl,
                    ),
                    children: [
                      // Header Icon & Title
                      Center(
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.verified_user_outlined,
                            size: 42,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      Gap.vMd,
                      Text(
                        ar
                            ? 'صلاحيات حماية وسلامة المريض'
                            : 'Permissions for your safety',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      Gap.vXs,
                      Text(
                        ar
                            ? 'نطلب هذه الصلاحيات لغايات طبية ووقائية بحتة لضمان استجابة النظام السريعة وإنقاذك في اللحظات الحرجة.'
                            : 'We ask for these only for medical safety: so the system can respond fast and get you help when it matters.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                      Gap.vLg,

                      // Permission 1: Emergency Notifications
                      _PermissionCard(
                        icon: Icons.notification_important_rounded,
                        color: AppColors.accent(
                          context,
                          AccentTone.orange,
                        ).foreground,
                        title: ar
                            ? 'التنبيهات الفورية وإشعارات الطوارئ'
                            : 'Instant and emergency notifications',
                        subtitle: ar
                            ? 'لإيقاظك وتنبيه مرافقك السريري وأسرتك قبل حدوث النوبة لتتمكن من اتخاذ وضعية الأمان والاستلقاء في مكان آمن.'
                            : 'To wake you and alert your caregiver and family before a seizure, so you can get to a safe position.',
                        granted: _notificationGranted,
                        onAction: _requestNotifications,
                        actionLabel: ar
                            ? 'السماح بالإشعارات'
                            : 'Allow notifications',
                      ),

                      Gap.vMd,

                      // Permission 2: GPS Location
                      _PermissionCard(
                        icon: Icons.my_location_rounded,
                        color: AppColors.accent(
                          context,
                          AccentTone.blue,
                        ).foreground,
                        title: ar
                            ? 'الموقع الجغرافي الدقيق للطوارئ'
                            : 'Precise location for emergencies',
                        subtitle: ar
                            ? 'لإرسال إحداثيات موقعك الجغرافي تلقائياً لأفراد أسرتك والإسعاف عند حدوث نوبة حادة أو طلب استغاثة SOS دون الحاجة للمس الهاتف.'
                            : 'To send your location to your family and responders automatically during a severe seizure or an SOS, without touching the phone.',
                        warning: _hasGps
                            ? null
                            : (ar
                                  ? 'هاتفك لا يحتوي شريحة GPS. دون إنترنت لن يُرسَل موقعك في الطوارئ؛ أضف «العنوان المعتاد» في البطاقة الطبية ليصل مع رسالة الاستغاثة.'
                                  : 'This phone has no GPS receiver. Without internet your location cannot be sent in an emergency; add a «usual address» to the medical card so it goes with the SOS message.'),
                        granted: _locationGranted,
                        onAction: _requestLocation,
                        actionLabel: _locationGranted
                            ? (ar ? 'تم المنح' : 'Granted')
                            : (ar ? 'السماح بالموقع' : 'Allow location'),
                      ),

                      Gap.vMd,

                      // Permission 3: Bluetooth & Sensor Connectivity
                      _PermissionCard(
                        icon: Icons.sensors_rounded,
                        color: AppColors.accent(
                          context,
                          AccentTone.green,
                        ).foreground,
                        title: ar
                            ? 'مصدر إشارات المستشعرات'
                            : 'Where sensor signals come from',
                        // No real permission exists in this build (no direct
                        // Bluetooth link); say so instead of a fake grant.
                        subtitle: ar
                            ? 'لا يلزم إذن في هذا الإصدار: تصل إشارات الدماغ والقلب من خادم الجهاز أو من المحاكي، ولا يوجد ربط Bluetooth مباشر بعد.'
                            : 'No permission needed in this version: brain and heart signals come from the device server or the simulator; there is no direct Bluetooth link yet.',
                        granted: true,
                        onAction: null,
                        actionLabel: '',
                      ),

                      Gap.vMd,

                      // Permission 4: Biometrics & Security
                      _PermissionCard(
                        icon: Icons.fingerprint_rounded,
                        color: AppColors.accent(
                          context,
                          AccentTone.indigo,
                        ).foreground,
                        title: ar
                            ? 'المصادقة الحيوية وحماية الخصوصية'
                            : 'Biometric sign-in and privacy',
                        subtitle: ar
                            ? 'لحماية تقاريرك الطبية الحساسة وتسهيل وصولك لحسابك السريري فوراً وبأمان تام دون كلمات مرور معقدة.'
                            : 'To protect your medical reports and let you into your account quickly and safely, without complex passwords.',
                        granted: true,
                        onAction: null,
                        actionLabel: ar
                            ? 'اختياري في الإعدادات'
                            : 'Optional, in settings',
                      ),
                    ],
                  ),
                ),

                // Bottom Action Button
                Container(
                  padding: const EdgeInsets.all(Gap.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    border: Border(
                      top: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.4,
                        ),
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: FilledButton.icon(
                          onPressed: _finish,
                          icon: const Icon(Icons.arrow_forward),
                          label: Text(
                            ar
                                ? 'متابعة إلى تسجيل الدخول'
                                : 'Continue to sign in',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(Radii.md),
                            ),
                          ),
                        ),
                      ),
                      Gap.vXs,
                      TextButton(
                        onPressed: _finish,
                        child: Text(
                          ar ? 'تخطي ومتابعة لاحقاً' : 'Skip for now',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.granted,
    required this.onAction,
    required this.actionLabel,
    this.warning,
  });

  /// Shown under the description when the phone lacks what this needs.
  final String? warning;
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool granted;
  final VoidCallback? onAction;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: granted
              ? color.withValues(alpha: 0.4)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          Gap.hMd,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (granted)
                      const Icon(
                        Icons.check_circle_rounded,
                        color: Colors.green,
                        size: 20,
                      ),
                  ],
                ),
                Gap.vXs,
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                if (warning != null) ...[
                  Gap.vSm,
                  Text(
                    warning!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.accent(
                        context,
                        AccentTone.orange,
                      ).foreground,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ],
                if (onAction != null && !granted) ...[
                  Gap.vSm,
                  // 48 dp minimum touch target (was 32 dp, below A11y floor).
                  OutlinedButton(
                    onPressed: onAction,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, A11y.minTouchTarget),
                      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                    ),
                    child: Text(actionLabel),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
