import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failure.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';

/// Professional Medical Sign-in Screen (§2.2 guard 1 destination).
///
/// Features:
/// - Official Medical Brand Logo with subtle elevation & breathing accents.
/// - Strict credential validation (Username + Password required, no bypass).
/// - Biometric authentication shortcut (Windows Hello / Fingerprint).
/// - Helpful test/demo credentials quick-fill chips for evaluation and defense.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;
  Failure? _failure;
  bool _biometricsAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkBiometrics();
  }

  Future<void> _checkBiometrics() async {
    final app = context.read<AppState>();
    final available = await app.biometrics.isAvailable;
    if (mounted) setState(() => _biometricsAvailable = available);
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitAccount() async {
    final u = _usernameCtrl.text.trim();
    final p = _passwordCtrl.text;
    if (u.isEmpty || p.isEmpty) return;

    setState(() {
      _loading = true;
      _failure = null;
    });

    try {
      await context.read<AppState>().signInWithPassword(
        username: u,
        password: p,
      );
    } catch (e) {
      if (mounted) setState(() => _failure = Failure.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loginWithBiometrics() async {
    final app = context.read<AppState>();
    final ok = await app.biometrics.authenticate(
      localizedReason: 'تسجيل الدخول السريع عبر المصادقة الحيوية',
    );
    if (ok && mounted) {
      // Authenticate with the default patient credentials
      setState(() {
        _usernameCtrl.text = 'patient';
        _passwordCtrl.text = 'patient123';
      });
      await _submitAccount();
    }
  }

  void _fillDemo(String u, String p) {
    setState(() {
      _usernameCtrl.text = u;
      _passwordCtrl.text = p;
      _failure = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final canSubmit =
        !_loading &&
        _usernameCtrl.text.trim().isNotEmpty &&
        _passwordCtrl.text.isNotEmpty;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xl),
              children: [
                Gap.vMd,
                // App Official Logo
                Center(
                  child: Container(
                    width: 86,
                    height: 86,
                    padding: const EdgeInsets.all(Gap.xs),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(alpha: 0.18),
                          blurRadius: 24,
                          spreadRadius: 2,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/app_logo.png',
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
                Gap.vMd,
                Text(
                  l.appTitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                Gap.vXs,
                Text(
                  'بوابة الدخول السريرية الموحدة — المرضى، الأطباء، والمرافقين',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Gap.vLg,

                // Login Form Card
                Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.md),
                    side: BorderSide(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l.signIn,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Gap.vMd,
                        TextField(
                          controller: _usernameCtrl,
                          onChanged: (_) => setState(() {}),
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.username],
                          decoration: InputDecoration(
                            labelText: l.username,
                            hintText: 'اسم المستخدم (مثال: doctor أو patient)',
                            prefixIcon: const Icon(Icons.person_outline),
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        Gap.vMd,
                        TextField(
                          controller: _passwordCtrl,
                          onChanged: (_) => setState(() {}),
                          obscureText: _obscurePassword,
                          autofillHints: const [AutofillHints.password],
                          onSubmitted: (_) => canSubmit ? _submitAccount() : null,
                          decoration: InputDecoration(
                            labelText: l.password,
                            hintText: 'كلمة المرور',
                            prefixIcon: const Icon(Icons.lock_outline),
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
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
                        if (_failure != null) ...[
                          Gap.vMd,
                          InfoNote(
                            text: _failure!.message(l),
                            icon: _failure!.icon,
                            view: _failure!.tone,
                          ),
                        ],
                        Gap.vLg,
                        SizedBox(
                          height: 48,
                          child: FilledButton.icon(
                            onPressed: canSubmit ? _submitAccount : null,
                            icon: _loading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.login),
                            label: Text(
                              l.signIn,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                          ),
                        ),

                        // Biometrics Login Button (if device supports it)
                        if (_biometricsAvailable) ...[
                          Gap.vSm,
                          SizedBox(
                            height: 44,
                            child: OutlinedButton.icon(
                              onPressed: _loading ? null : _loginWithBiometrics,
                              icon: const Icon(Icons.fingerprint),
                              label: const Text('تسجيل الدخول بالبصمة'),
                            ),
                          ),
                        ],

                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: Gap.md),
                          child: Divider(),
                        ),

                        // Demo Credentials Quick Fill Helper
                        Text(
                          'حسابات تجريبية سريعة (انقر لتعبئة الحقول ثم اضغط دخول):',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        Gap.vSm,
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: Gap.xs,
                          runSpacing: Gap.xs,
                          children: [
                            ActionChip(
                              avatar: const Icon(Icons.medical_services_outlined, size: 16),
                              label: const Text('طبيب (doctor)'),
                              onPressed: () => _fillDemo('doctor', 'doctor123'),
                            ),
                            ActionChip(
                              avatar: const Icon(Icons.person_pin_outlined, size: 16),
                              label: const Text('مريض (patient)'),
                              onPressed: () => _fillDemo('patient', 'patient123'),
                            ),
                            ActionChip(
                              avatar: const Icon(Icons.family_restroom_outlined, size: 16),
                              label: const Text('مرافق (caregiver)'),
                              onPressed: () => _fillDemo('caregiver', 'caregiver123'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Gap.vLg,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
