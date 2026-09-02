import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../core/errors/failure.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';

/// Sign-in (§2.2 guard 1's destination).
///
/// The role dropdown belongs to demo mode only: a real sign-in gets its role
/// from the backend session, never from a value the client picked. Letting the
/// user choose it would make the role a client-side claim.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  UserRole _role = UserRole.patient;
  bool _loading = false;
  bool _obscurePassword = true;
  Failure? _failure;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  String _roleLabel(UserRole role, AppLocalizations l) => switch (role) {
    UserRole.patient => l.rolePatient,
    UserRole.caregiver => l.roleCaregiver,
    UserRole.doctor => l.roleDoctor,
  };

  Future<void> _submitAccount() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      await context.read<AppState>().signInWithPassword(
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text,
      );
    } catch (e) {
      // signInWithPassword throws a Failure; anything else is normalised here so
      // the user still sees one localised sentence rather than an exception.
      if (mounted) setState(() => _failure = Failure.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitDemo() async {
    final l = AppLocalizations.of(context);
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      await context.read<AppState>().signInDemo(
        name: l.demoUserName,
        email: 'demo@epilepsy.local',
        role: _role,
      );
    } catch (e) {
      if (mounted) setState(() => _failure = Failure.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
      // No gradient: the theme owns colour now, so this screen looks right in
      // dark mode instead of forcing a light card onto a dark background (§2.4).
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              padding: Insets.page,
              children: [
                Gap.vXl,
                Icon(
                  Icons.monitor_heart_outlined,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                Gap.vMd,
                Text(
                  l.appTitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Gap.vXs,
                Text(
                  l.appTagline,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Gap.vXl,
                Card(
                  child: Padding(
                    padding: Insets.card,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _usernameCtrl,
                          onChanged: (_) => setState(() {}),
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.username],
                          decoration: InputDecoration(
                            labelText: l.username,
                            prefixIcon: const Icon(Icons.person_outline),
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
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              tooltip: _obscurePassword
                                  ? l.showPassword
                                  : l.hidePassword,
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
                          height: A11y.minTouchTarget,
                          child: FilledButton.icon(
                            onPressed: canSubmit ? _submitAccount : null,
                            icon: _loading
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.login),
                            label: Text(l.signIn),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: Gap.lg),
                          child: Divider(),
                        ),
                        DropdownButtonFormField<UserRole>(
                          initialValue: _role,
                          decoration: InputDecoration(labelText: l.roleLabel),
                          items: [
                            for (final r in UserRole.values)
                              DropdownMenuItem(
                                value: r,
                                child: Text(_roleLabel(r, l)),
                              ),
                          ],
                          onChanged: _loading
                              ? null
                              : (v) =>
                                    setState(() => _role = v ?? UserRole.patient),
                        ),
                        Gap.vMd,
                        SizedBox(
                          height: A11y.minTouchTarget,
                          child: OutlinedButton.icon(
                            onPressed: _loading ? null : _submitDemo,
                            icon: const Icon(Icons.science_outlined),
                            label: Text(l.signInDemo),
                          ),
                        ),
                        Gap.vSm,
                        Text(
                          l.demoNote,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
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
    );
  }
}
