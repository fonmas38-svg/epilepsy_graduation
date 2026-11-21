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

/// Sign in with a server-assigned role. Connection diagnostics are secondary.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _customUrlCtrl = TextEditingController();

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
    _usernameCtrl.addListener(_onUsernameChanged);
    _loadSavedUsername();
  }

  void _onUsernameChanged() {
    _checkBiometrics(username: _usernameCtrl.text);
  }

  @override
  void dispose() {
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
      final enabled =
          bound != null && await app.biometrics.isEnabledForUser(bound);
      if (mounted) {
        setState(() {
          _boundBiometricUser = enabled ? bound : null;
          _biometricsAvailable = available && enabled;
        });
      }
    }
  }

  Future<void> _submitAccount({
    String? overrideUser,
    String? overridePass,
  }) async {
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
    final targetUser = (_boundBiometricUser ?? _usernameCtrl.text)
        .trim()
        .toLowerCase();

    if (targetUser.isEmpty || !_biometricsAvailable) {
      if (mounted) {
        AppSnack.warn(
          context,
          'لم يتم تفعيل البصمة لهذا الحساب على هذا الجهاز',
        );
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

    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      await app.signInWithBiometrics(targetUser);
      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppRouter.rootFor(app.auth.currentUser?.role),
          (r) => false,
        );
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
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
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
          isSelected
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked,
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.outline,
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
    final ar = l.isArabic;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 960;
            final form = AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFFDBEAFE), width: 1.5),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x080066FF),
                            blurRadius: 12,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.monitor_heart_rounded,
                        size: 42,
                        color: Color(0xFF0066FF),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    ar ? 'مرحبًا بعودتك' : 'Welcome back',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0D253C),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    ar
                        ? 'سجّل الدخول إلى حسابك للمتابعة'
                        : 'Sign in to continue',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _usernameCtrl,
                    enabled: !_loading,
                    autofillHints: const [AutofillHints.username],
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: ar ? 'اسم المستخدم' : 'Username',
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordCtrl,
                    enabled: !_loading,
                    obscureText: _obscurePassword,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      if (!_loading) _submitAccount();
                    },
                    decoration: InputDecoration(
                      labelText: ar ? 'كلمة المرور' : 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: ar
                            ? 'إظهار أو إخفاء كلمة المرور'
                            : 'Show or hide password',
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                  CheckboxListTile(
                    value: _rememberMe,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(ar ? 'تذكر اسم المستخدم' : 'Remember username'),
                    onChanged: _loading
                        ? null
                        : (value) =>
                              setState(() => _rememberMe = value ?? false),
                  ),
                  if (_failure != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _failure!.message(l),
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0066FF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      onPressed:
                          _loading ||
                              _usernameCtrl.text.trim().isEmpty ||
                              _passwordCtrl.text.isEmpty
                          ? null
                          : () => _submitAccount(),
                      child: _loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              ar ? 'تسجيل الدخول' : 'Sign in',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  if (_biometricsAvailable) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _loading ? null : _loginWithBiometrics,
                      icon: const Icon(Icons.fingerprint),
                      label: Text(
                        ar ? 'الدخول بالبصمة' : 'Sign in with biometrics',
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      ar
                          ? 'تحتاج حسابًا أو مساعدة للدخول؟'
                          : 'Need an account or help signing in?',
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          ar
                              ? 'ينشئ الطبيب أو مسؤول النظام حساب المريض. يمكن للمريض إضافة مرافق من إعدادات حسابه. لاستعادة الوصول تواصل مع المسؤول المخوّل؛ الاستعادة الذاتية غير متاحة بعد.'
                              : 'A doctor or administrator creates patient accounts. Patients can add a caregiver in account settings. Contact your authorized administrator to recover access; self-service recovery is not available yet.',
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    child: Center(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _showServerSettingsModal(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (app.isCheckingServer) ...[
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  ar ? 'جارٍ فحص الاتصال بالخادم...' : 'Checking server...',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF0066FF),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ] else if (!app.apiOnline) ...[
                                const Icon(
                                  Icons.cloud_off_rounded,
                                  size: 16,
                                  color: Color(0xFFD97706),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  ar
                                      ? 'الخادم غير متصل (اضغط لتغيير الخادم أو إعادة الفحص)'
                                      : 'Server offline (tap to retry or configure)',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFFD97706),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ] else ...[
                                const Icon(
                                  Icons.cloud_done_rounded,
                                  size: 16,
                                  color: Color(0xFF059669),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  ar ? 'متصل بالخادم السحابي' : 'Connected to cloud server',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF059669),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (AppConfig.demoMode)
                    Wrap(
                      spacing: 8,
                      children: UserRole.values
                          .map(
                            (role) => ChoiceChip(
                              label: Text(role.name),
                              selected: _selectedRole == role,
                              onSelected: (_) => _fillRoleDemo(role),
                            ),
                          )
                          .toList(),
                    ),
                ],
              ),
            );
            return Row(
              children: [
                if (wide)
                  Expanded(
                    child: Container(
                      color: theme.colorScheme.primaryContainer,
                      padding: const EdgeInsets.all(48),
                      alignment: Alignment.center,
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onLongPress: () => _showServerSettingsModal(context),
                              child: Icon(
                                Icons.monitor_heart_outlined,
                                size: 100,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 32),
                            Text(
                              ar
                                  ? 'رعاية أقرب، ومتابعة أوضح'
                                  : 'Closer care. Clearer monitoring.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.headlineLarge?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              ar
                                  ? 'السجل والأدوية والتنبيهات والتواصل مع فريق الرعاية في مكان واحد.'
                                  : 'Records, medication, alerts and your care team in one place.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 500),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(wide ? 40 : 24),
                        child: form,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
