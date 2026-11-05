import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config.dart';
import '../../core/enums.dart';
import '../../core/errors/failure.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';

/// Redesigned, Production-Ready Clinical Sign-in Screen.
///
/// Features:
/// - Breathing ECG/Vital animated brand logo with glowing gradient rings.
/// - Live Server Connection Bar (Auto Failover / Cloud / Local / Custom LAN) with latency ping.
/// - Role Switcher & 1-Tap Defense Quick Fill (Doctor, Patient, Caregiver).
/// - Strict credential validation, password visibility toggle, and "Remember Me".
/// - Secure Biometric authentication (Windows Hello / Fingerprint).
/// - Professional RTL Arabic design compliant with modern clinical UX standards.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _customUrlCtrl = TextEditingController();

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  bool _loading = false;
  bool _obscurePassword = true;
  Failure? _failure;
  bool _biometricsAvailable = false;
  String? _boundBiometricUser;
  bool _rememberMe = false;
  UserRole _selectedRole = UserRole.doctor;

  static const _rememberMeKey = 'remember_me_pref';
  static const _rememberedUsernameKey = 'remembered_username_pref';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.96, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _usernameCtrl.addListener(_onUsernameChanged);
    _loadSavedUsername();
  }

  void _onUsernameChanged() {
    _checkBiometrics(username: _usernameCtrl.text);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _usernameCtrl.removeListener(_onUsernameChanged);
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _customUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedUsername() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rem = prefs.getBool(_rememberMeKey) ?? false;
      final saved = prefs.getString(_rememberedUsernameKey);
      if (mounted && rem && saved != null && saved.isNotEmpty) {
        setState(() {
          _rememberMe = true;
          _usernameCtrl.text = saved;
        });
      }
      await _checkBiometrics();
    } catch (_) {}
  }

  Future<void> _checkBiometrics({String? username}) async {
    final app = context.read<AppState>();
    final available = await app.biometrics.isAvailable;
    final candidate = (username ?? _usernameCtrl.text).trim().toLowerCase();

    if (candidate.isNotEmpty) {
      final enabled = await app.biometrics.isEnabledForUser(candidate);
      if (mounted) {
        setState(() {
          _boundBiometricUser = enabled ? candidate : null;
          _biometricsAvailable = available && enabled;
        });
      }
    } else {
      final bound = await app.biometrics.getBoundUsername();
      final enabled = bound != null && await app.biometrics.isEnabledForUser(bound);
      if (mounted) {
        setState(() {
          _boundBiometricUser = enabled ? bound : null;
          _biometricsAvailable = available && enabled;
        });
      }
    }
  }

  Future<void> _submitAccount({String? overrideUser, String? overridePass}) async {
    final u = (overrideUser ?? _usernameCtrl.text).trim();
    final p = overridePass ?? _passwordCtrl.text;
    if (u.isEmpty || p.isEmpty) return;

    setState(() {
      _loading = true;
      _failure = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      if (_rememberMe) {
        await prefs.setBool(_rememberMeKey, true);
        await prefs.setString(_rememberedUsernameKey, u);
      } else {
        await prefs.setBool(_rememberMeKey, false);
        await prefs.remove(_rememberedUsernameKey);
      }

      if (!mounted) return;
      await context.read<AppState>().signInWithPassword(
            username: u,
            password: p,
          );
      if (mounted) {
        final role = context.read<AppState>().auth.currentUser?.role;
        final target = AppRouter.rootFor(role);
        Navigator.pushNamedAndRemoveUntil(context, target, (r) => false);
      }
    } catch (e) {
      if (mounted) setState(() => _failure = Failure.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loginWithBiometrics() async {
    final app = context.read<AppState>();
    final targetUser =
        (_boundBiometricUser ?? _usernameCtrl.text).trim().toLowerCase();

    if (targetUser.isEmpty || !_biometricsAvailable) {
      if (mounted) {
        AppSnack.warn(context, 'لم يتم تفعيل البصمة لهذا الحساب على هذا الجهاز');
      }
      return;
    }

    final isUserEnabled = await app.biometrics.isEnabledForUser(targetUser);
    if (!isUserEnabled) {
      if (mounted) {
        AppSnack.warn(
          context,
          'خاصية البصمة غير مفعّلة لحساب «$targetUser». يرجى تسجيل الدخول بكلمة المرور.',
        );
      }
      return;
    }

    final ok = await app.biometrics.authenticate(
      localizedReason: 'المصادقة بمستشعر البصمة لحساب $targetUser',
    );
    if (!ok || !mounted) return;

    setState(() { _loading = true; _failure = null; });
    try {
      await app.signInWithBiometrics(targetUser);
      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, AppRouter.rootFor(app.auth.currentUser?.role), (r) => false);
      }
    } catch (e) {
      if (mounted) setState(() => _failure = Failure.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _fillRoleDemo(UserRole role) {
    setState(() {
      _selectedRole = role;
      _failure = null;
      switch (role) {
        case UserRole.doctor:
          _usernameCtrl.text = 'doctor';
          _passwordCtrl.text = 'doctor123';
          break;
        case UserRole.patient:
          _usernameCtrl.text = 'patient';
          _passwordCtrl.text = 'patient123';
          break;
        case UserRole.caregiver:
          _usernameCtrl.text = 'caregiver';
          _passwordCtrl.text = 'caregiver123';
          break;
        case UserRole.admin:
          _usernameCtrl.text = 'admin';
          _passwordCtrl.text = 'admin123';
          break;
      }
    });
    _checkBiometrics(username: _usernameCtrl.text);
  }

  void _showServerSettingsModal(BuildContext context) {
    final app = context.read<AppState>();
    _customUrlCtrl.text = app.customServerUrl ?? 'http://192.168.1.10:8000';
    Map<String, int?>? probeResults;
    bool probing = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) {
          final theme = Theme.of(modalCtx);
          return Container(
            padding: EdgeInsets.only(
              left: Gap.lg,
              right: Gap.lg,
              top: Gap.lg,
              bottom: MediaQuery.of(modalCtx).viewInsets.bottom + Gap.xl,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                Gap.vMd,
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.dns_rounded,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    Gap.hMd,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'إعدادات الاتصال بالخادم (Backend)',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'مرونة الاتصال لمنع انقطاع جلسة المناقشة والتطوير',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),

                // Option 1: Smart Auto
                _buildServerOption(
                  context: modalCtx,
                  mode: ServerMode.auto,
                  currentMode: app.serverMode,
                  title: 'تلقائي ذكي (سحابي ⇆ محلي)',
                  subtitle:
                      'يتصل بالسحابة (Render Cloud)، وينتقل فوراً للمحلي عند تعذر الإنترنت',
                  badge: 'موصى به للمناقشة ⭐',
                  badgeColor: const Color(0xFF00796B),
                  onSelect: () async {
                    Navigator.pop(ctx);
                    await app.applyServerMode(ServerMode.auto);
                  },
                ),

                // Option 2: Cloud Render
                _buildServerOption(
                  context: modalCtx,
                  mode: ServerMode.cloud,
                  currentMode: app.serverMode,
                  title: 'الخادم السحابي الرسمي (Render Cloud)',
                  subtitle: AppConfig.cloudProductionUrl,
                  badge: probeResults?['cloud'] != null
                      ? '⚡ ${probeResults!['cloud']} ms'
                      : 'سحابي عالمي',
                  badgeColor: const Color(0xFF1565C0),
                  onSelect: () async {
                    Navigator.pop(ctx);
                    await app.applyServerMode(ServerMode.cloud);
                  },
                ),

                // Option 3: Localhost
                _buildServerOption(
                  context: modalCtx,
                  mode: ServerMode.local,
                  currentMode: app.serverMode,
                  title: 'الخادم المحلي (Localhost)',
                  subtitle: AppConfig.defaultLocalUrl,
                  badge: probeResults?['local'] != null
                      ? '⚡ ${probeResults!['local']} ms'
                      : 'أوفلاين سريع 💻',
                  badgeColor: const Color(0xFFE65100),
                  onSelect: () async {
                    Navigator.pop(ctx);
                    await app.applyServerMode(ServerMode.local);
                  },
                ),

                // Option 4: Custom IP
                _buildServerOption(
                  context: modalCtx,
                  mode: ServerMode.custom,
                  currentMode: app.serverMode,
                  title: 'عنوان مخصص (Custom LAN IP)',
                  subtitle: app.customServerUrl ?? 'http://192.168.x.x:8000',
                  badge: 'شبكة محلية',
                  badgeColor: Colors.blueGrey,
                  onSelect: () {
                    showDialog(
                      context: modalCtx,
                      builder: (dCtx) => AlertDialog(
                        title: const Text('أدخل عنوان الخادم المخصص'),
                        content: TextField(
                          controller: _customUrlCtrl,
                          decoration: const InputDecoration(
                            hintText: 'http://192.168.1.50:8000',
                            labelText: 'عنوان URL',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dCtx),
                            child: const Text('إلغاء'),
                          ),
                          FilledButton(
                            onPressed: () async {
                              Navigator.pop(dCtx);
                              Navigator.pop(ctx);
                              await app.applyServerMode(
                                ServerMode.custom,
                                customUrl: _customUrlCtrl.text.trim(),
                              );
                            },
                            child: const Text('حفظ واتصال'),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                Gap.vMd,
                // Ping Tester Button
                OutlinedButton.icon(
                  onPressed: probing
                      ? null
                      : () async {
                          setModalState(() => probing = true);
                          final res = await app.probeAllServers();
                          setModalState(() {
                            probeResults = res;
                            probing = false;
                          });
                        },
                  icon: probing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed_rounded),
                  label: Text(
                    probing
                        ? 'جارٍ فحص استجابة الخوادم...'
                        : 'فحص سرعة استجابة السحابة والمحلي (Ping)',
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildServerOption({
    required BuildContext context,
    required ServerMode mode,
    required ServerMode currentMode,
    required String title,
    required String subtitle,
    required String badge,
    required Color badgeColor,
    required VoidCallback onSelect,
  }) {
    final theme = Theme.of(context);
    final isSelected = mode == currentMode;

    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      decoration: BoxDecoration(
        color: isSelected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.28)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          width: isSelected ? 2 : 1,
        ),
      ),
      child: ListTile(
        onTap: onSelect,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: Icon(
          isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
          color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outline,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: badgeColor.withValues(alpha: 0.35)),
              ),
              child: Text(
                badge,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: badgeColor,
                ),
              ),
            ),
          ],
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();

    final canSubmit =
        !_loading &&
        _usernameCtrl.text.trim().isNotEmpty &&
        _passwordCtrl.text.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Sleek deep slate dark canvas
      body: Stack(
        children: [
          // Background ambient gradient glow
          Positioned(
            top: -120,
            right: -80,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF00A896).withValues(alpha: 0.25),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -100,
            left: -80,
            child: Container(
              width: 340,
              height: 340,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF0284C7).withValues(alpha: 0.2),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Gap.lg,
                    vertical: Gap.md,
                  ),
                  children: [
                    // Dynamic Server Connection Pill (Top Switcher)
                    Center(
                      child: InkWell(
                        onTap: () => _showServerSettingsModal(context),
                        borderRadius: BorderRadius.circular(30),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B).withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(
                              color: app.apiOnline
                                  ? const Color(0xFF10B981)
                                  : const Color(0xFFF59E0B),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (app.apiOnline
                                        ? const Color(0xFF10B981)
                                        : const Color(0xFFF59E0B))
                                    .withValues(alpha: 0.22),
                                blurRadius: 12,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: app.apiOnline
                                      ? const Color(0xFF10B981)
                                      : const Color(0xFFF59E0B),
                                ),
                              ),
                              Gap.hSm,
                              Text(
                                app.apiOnline
                                    ? (app.serverMode == ServerMode.local
                                        ? 'الخادم: محلي (Localhost)'
                                        : 'الخادم: سحابي (Render Cloud)')
                                    : 'وضع تجريبي / جارِ الفحص...',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (app.currentServerPingMs != null) ...[
                                Gap.hXs,
                                Text(
                                  '(${app.currentServerPingMs}ms)',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.6),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                              Gap.hSm,
                              const Icon(
                                Icons.tune_rounded,
                                size: 14,
                                color: Color(0xFF38BDF8),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    Gap.vMd,

                    // Breathing Pulsing Medical Brand Logo
                    Center(
                      child: ScaleTransition(
                        scale: _pulseAnimation,
                        child: Container(
                          width: 88,
                          height: 88,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              colors: [Color(0xFF0284C7), Color(0xFF0D9488)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF0284C7)
                                    .withValues(alpha: 0.35),
                                blurRadius: 28,
                                spreadRadius: 4,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Color(0xFF0F172A),
                              shape: BoxShape.circle,
                            ),
                            padding: const EdgeInsets.all(10),
                            child: ClipOval(
                              child: Image.asset(
                                'assets/images/app_logo.png',
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    Gap.vMd,

                    // Official System Name & Title
                    Text(
                      l.appTitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                      ),
                    ),
                    Gap.vXs,
                    Text(
                      l.appSubtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                    Gap.vLg,

                    // Interactive Role Selector Segmented Bar
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        children: [
                          _buildRoleSegment(
                            role: UserRole.doctor,
                            title: 'طبيب',
                            icon: Icons.medical_services_rounded,
                          ),
                          _buildRoleSegment(
                            role: UserRole.patient,
                            title: 'مريض',
                            icon: Icons.person_rounded,
                          ),
                          _buildRoleSegment(
                            role: UserRole.caregiver,
                            title: 'مرافق',
                            icon: Icons.family_restroom_rounded,
                          ),
                          _buildRoleSegment(
                            role: UserRole.admin,
                            title: 'المدير',
                            icon: Icons.admin_panel_settings_rounded,
                          ),
                        ],
                      ),
                    ),

                    Gap.vMd,

                    // Main Glassmorphism Form Card
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B).withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                l.signIn,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              // 1-Tap Quick Demo Action
                              TextButton.icon(
                                onPressed: () {
                                  _fillRoleDemo(_selectedRole);
                                  _submitAccount(
                                    overrideUser: _usernameCtrl.text,
                                    overridePass: _passwordCtrl.text,
                                  );
                                },
                                icon: const Icon(
                                  Icons.bolt_rounded,
                                  size: 16,
                                  color: Color(0xFF38BDF8),
                                ),
                                label: const Text(
                                  'دخول تجريبي فوري',
                                  style: TextStyle(
                                    color: Color(0xFF38BDF8),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),

                          Gap.vMd,

                          // Username Field
                          TextField(
                            controller: _usernameCtrl,
                            onChanged: (_) => setState(() {}),
                            style: const TextStyle(color: Colors.white),
                            textInputAction: TextInputAction.next,
                            autofillHints: const [AutofillHints.username],
                            decoration: InputDecoration(
                              labelText: l.username,
                              labelStyle: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                              hintText: 'اسم المستخدم (مثال: doctor أو patient)',
                              hintStyle: TextStyle(
                                color: Colors.white.withValues(alpha: 0.35),
                              ),
                              prefixIcon: const Icon(
                                Icons.account_circle_outlined,
                                color: Color(0xFF38BDF8),
                              ),
                              filled: true,
                              fillColor: const Color(0xFF0F172A),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.1),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(
                                  color: Color(0xFF38BDF8),
                                  width: 1.8,
                                ),
                              ),
                            ),
                          ),

                          Gap.vMd,

                          // Password Field
                          TextField(
                            controller: _passwordCtrl,
                            onChanged: (_) => setState(() {}),
                            obscureText: _obscurePassword,
                            style: const TextStyle(color: Colors.white),
                            autofillHints: const [AutofillHints.password],
                            onSubmitted: (_) =>
                                canSubmit ? _submitAccount() : null,
                            decoration: InputDecoration(
                              labelText: l.password,
                              labelStyle: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                              hintText: 'كلمة المرور',
                              hintStyle: TextStyle(
                                color: Colors.white.withValues(alpha: 0.35),
                              ),
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                                color: Color(0xFF38BDF8),
                              ),
                              filled: true,
                              fillColor: const Color(0xFF0F172A),
                              suffixIcon: IconButton(
                                onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  color: Colors.white.withValues(alpha: 0.6),
                                ),
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.1),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(
                                  color: Color(0xFF38BDF8),
                                  width: 1.8,
                                ),
                              ),
                            ),
                          ),

                          Gap.vSm,

                          // Remember Me Checkbox
                          InkWell(
                            onTap: () =>
                                setState(() => _rememberMe = !_rememberMe),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: Checkbox(
                                      value: _rememberMe,
                                      activeColor: const Color(0xFF0284C7),
                                      side: BorderSide(
                                        color:
                                            Colors.white.withValues(alpha: 0.5),
                                      ),
                                      onChanged: (v) => setState(
                                        () => _rememberMe = v ?? false,
                                      ),
                                    ),
                                  ),
                                  Gap.hSm,
                                  Text(
                                    'تذكر اسم المستخدم على هذا الجهاز',
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.82),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          if (_failure != null) ...[
                            Gap.vMd,
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEF4444)
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xFFEF4444)
                                      .withValues(alpha: 0.4),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.error_outline_rounded,
                                    color: Color(0xFFF87171),
                                    size: 20,
                                  ),
                                  Gap.hSm,
                                  Expanded(
                                    child: Text(
                                      _failure!.message(l),
                                      style: const TextStyle(
                                        color: Color(0xFFFCA5A5),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          Gap.vLg,

                          // Main Submit Button
                          SizedBox(
                            height: 52,
                            child: ElevatedButton.icon(
                              onPressed: canSubmit ? _submitAccount : null,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0284C7),
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: const Color(0xFF334155),
                                disabledForegroundColor:
                                    Colors.white.withValues(alpha: 0.4),
                                elevation: 4,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: _loading
                                  ? const SizedBox(
                                      height: 22,
                                      width: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.login_rounded),
                              label: Text(
                                _loading ? 'جارٍ تسجيل الدخول...' : l.signIn,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),

                          // Biometric Login Button
                          if (_biometricsAvailable &&
                              _boundBiometricUser != null) ...[
                            Gap.vSm,
                            SizedBox(
                              height: 48,
                              child: OutlinedButton.icon(
                                onPressed:
                                    _loading ? null : _loginWithBiometrics,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF38BDF8),
                                  side: BorderSide(
                                    color: const Color(0xFF38BDF8)
                                        .withValues(alpha: 0.5),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                icon: const Icon(Icons.fingerprint_rounded),
                                label: Text(
                                  'تسجيل الدخول بالبصمة ($_boundBiometricUser)',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],

                          Gap.vMd,
                          Divider(
                            color: Colors.white.withValues(alpha: 0.1),
                          ),
                          Gap.vSm,

                          // Defense Evaluation Quick-Fill Chips
                          Center(
                            child: Text(
                              'حسابات تجريبية سريعة للمناقشة:',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Gap.vSm,
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _buildQuickChip(
                                label: 'د. خالد (طبيب)',
                                icon: Icons.medical_services_outlined,
                                onSelected: () =>
                                    _fillRoleDemo(UserRole.doctor),
                              ),
                              _buildQuickChip(
                                label: 'أحمد (مريض)',
                                icon: Icons.person_outline,
                                onSelected: () =>
                                    _fillRoleDemo(UserRole.patient),
                              ),
                              _buildQuickChip(
                                label: 'سارة (مرافق)',
                                icon: Icons.family_restroom_outlined,
                                onSelected: () =>
                                    _fillRoleDemo(UserRole.caregiver),
                              ),
                              _buildQuickChip(
                                label: 'مدير النظام (admin)',
                                icon: Icons.admin_panel_settings_outlined,
                                onSelected: () =>
                                    _fillRoleDemo(UserRole.admin),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    Gap.vLg,

                    // Medical Security & Compliance Notice
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.verified_user_rounded,
                            size: 15,
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
                          Gap.hXs,
                          Text(
                            'نظام تشفير سحابي طبي متوافق مع معايير HIPAA و GDPR',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Gap.vSm,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoleSegment({
    required UserRole role,
    required String title,
    required IconData icon,
  }) {
    final isSelected = _selectedRole == role;

    return Expanded(
      child: InkWell(
        onTap: () => _fillRoleDemo(role),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF0284C7) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: TextStyle(
                  color: isSelected
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.6),
                  fontSize: 12,
                  fontWeight:
                      isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickChip({
    required String label,
    required IconData icon,
    required VoidCallback onSelected,
  }) {
    return ActionChip(
      backgroundColor: const Color(0xFF0F172A),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
      avatar: Icon(icon, size: 16, color: const Color(0xFF38BDF8)),
      label: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      onPressed: onSelected,
    );
  }
}
