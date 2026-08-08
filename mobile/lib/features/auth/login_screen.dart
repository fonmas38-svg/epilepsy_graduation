import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../providers/app_state.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _nameCtrl = TextEditingController(text: 'مستخدم تجريبي');
  final _emailCtrl = TextEditingController(text: 'demo@epilepsy.local');
  UserRole _role = UserRole.patient;
  bool _loading = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _loading = true);
    try {
      final state = context.read<AppState>();
      await state.signIn(
            name: _nameCtrl.text.trim().isEmpty ? 'مستخدم' : _nameCtrl.text.trim(),
            email: _emailCtrl.text.trim(),
            role: _role,
          );
      // Surface any non-fatal issue (offline backend, keystore fallback) so the
      // user understands why analysis may be degraded — without blocking login.
      if (mounted && state.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(state.error!)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذّر تسجيل الدخول: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [Color(0xFF0B3D4A), Color(0xFF145C6B), Color(0xFFE8F3F1)],
            stops: [0, 0.45, 1],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 24),
                  Text(
                    'Epilepsy Monitor',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'مراقبة مرضى الصرع والتنبؤ المبكر بالنوبات',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                  ),
                  const SizedBox(height: 32),
                  Card(
                    elevation: 0,
                    color: Colors.white.withValues(alpha: 0.96),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _nameCtrl,
                            decoration: const InputDecoration(
                              labelText: 'الاسم',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _emailCtrl,
                            decoration: const InputDecoration(
                              labelText: 'البريد',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<UserRole>(
                            initialValue: _role,
                            decoration: const InputDecoration(
                              labelText: 'الدور',
                              border: OutlineInputBorder(),
                            ),
                            items: UserRole.values
                                .map(
                                  (r) => DropdownMenuItem(
                                    value: r,
                                    child: Text(r.labelAr),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setState(() => _role = v ?? UserRole.patient),
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Text('دخول تجريبي'),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'وضع العرض يعمل بدون Firebase. لربط مشروع حقيقي عطّل DEMO_MODE.',
                            style: Theme.of(context).textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
