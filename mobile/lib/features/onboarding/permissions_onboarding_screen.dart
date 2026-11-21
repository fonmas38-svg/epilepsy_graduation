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
  bool _sensorsGranted = true;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    try {
      final loc = await Geolocator.checkPermission();
      if (loc == LocationPermission.always ||
          loc == LocationPermission.whileInUse) {
        if (mounted) setState(() => _locationGranted = true);
      }
    } catch (_) {}
  }

  Future<void> _requestLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        final ok = await _promptDialog(
          title: 'خدمة تحديد الموقع (GPS) مغلقة',
          body:
              'خدمة الـ GPS مغلقة في هاتفك. يرجى تفعيل الموقع لتمكين النظام من تحديد مكانك وقت الطوارئ.',
          actionText: 'تفعيل الـ GPS',
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
          title: 'إذن الموقع معطل في إعدادات الهاتف',
          body:
              'تم رفض إذن الموقع للتطبيق سابقاً. يرجى فتح إعدادات التطبيق وتفعيل إذن «الموقع» لحمايتك.',
          actionText: 'فتح الإعدادات',
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
            child: const Text('إلغاء'),
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
                            color: const Color(0xFF1B4965).withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.verified_user_outlined,
                            size: 42,
                            color: Color(0xFF1B4965),
                          ),
                        ),
                      ),
                      Gap.vMd,
                      Text(
                        'صلاحيات حماية وسلامة المريض',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      Gap.vXs,
                      Text(
                        'نطلب هذه الصلاحيات لغايات طبية ووقائية بحتة لضمان استجابة النظام السريعة وإنقاذك في اللحظات الحرجة.',
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
                        color: const Color(0xFFE65100),
                        title: 'التنبيهات الفورية وإشعارات الطوارئ',
                        subtitle:
                            'لإيقاظك وتنبيه مرافقك السريري وأسرتك قبل حدوث النوبة لتتمكن من اتخاذ وضعية الأمان والاستلقاء في مكان آمن.',
                        granted: _notificationGranted,
                        onAction: () => setState(() => _notificationGranted = true),
                        actionLabel: 'مُفعلة للأمان',
                      ),

                      Gap.vMd,

                      // Permission 2: GPS Location
                      _PermissionCard(
                        icon: Icons.my_location_rounded,
                        color: const Color(0xFF0288D1),
                        title: 'الموقع الجغرافي الدقيق للطوارئ',
                        subtitle:
                            'لإرسال إحداثيات موقعك الجغرافي تلقائياً لأفراد أسرتك والإسعاف عند حدوث نوبة حادة أو طلب استغاثة SOS دون الحاجة للمس الهاتف.',
                        granted: _locationGranted,
                        onAction: _requestLocation,
                        actionLabel: _locationGranted ? 'تم المنح' : 'السماح بالموقع',
                      ),

                      Gap.vMd,

                      // Permission 3: Bluetooth & Sensor Connectivity
                      _PermissionCard(
                        icon: Icons.sensors_rounded,
                        color: const Color(0xFF2E7D32),
                        title: 'الاتصال بالمستشعرات وأجهزة الارتداء',
                        subtitle:
                            'لقراءة وتخطيط نبضات القلب وإشارات الدماغ ونقلها إلى محلل الذكاء الاصطناعي اللحظي لرصد بدايات النوبة.',
                        granted: _sensorsGranted,
                        onAction: () => setState(() => _sensorsGranted = true),
                        actionLabel: 'مُفعل تلقائياً',
                      ),

                      Gap.vMd,

                      // Permission 4: Biometrics & Security
                      _PermissionCard(
                        icon: Icons.fingerprint_rounded,
                        color: const Color(0xFF6A1B9A),
                        title: 'المصادقة الحيوية وحماية الخصوصية',
                        subtitle:
                            'لحماية تقاريرك الطبية الحساسة وتسهيل وصولك لحسابك السريري فوراً وبأمان تام دون كلمات مرور معقدة.',
                        granted: true,
                        onAction: null,
                        actionLabel: 'اختياري في الإعدادات',
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
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
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
                          label: const Text(
                            'متابعة إلى تسجيل الدخول',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1B4965),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(Radii.md),
                            ),
                          ),
                        ),
                      ),
                      Gap.vXs,
                      TextButton(
                        onPressed: _finish,
                        child: const Text('تخطي ومتابعة لاحقاً'),
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
  });

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
                if (onAction != null && !granted) ...[
                  Gap.vSm,
                  SizedBox(
                    height: 32,
                    child: OutlinedButton(
                      onPressed: onAction,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      ),
                      child: Text(actionLabel, style: const TextStyle(fontSize: 12)),
                    ),
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
