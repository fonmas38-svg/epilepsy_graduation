import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../features/shared/first_aid_view.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/biometric_service.dart';

/// A local privacy lock, independent of logout and server revocation.
class InactivityWatcher extends StatefulWidget {
  const InactivityWatcher({
    super.key,
    required this.child,
    this.timeout = const Duration(minutes: 5),
    this.enabled = true,
    this.verifier,
  });
  final Widget child;
  final Duration timeout;
  final bool enabled;
  final BiometricService? verifier;
  @override
  State<InactivityWatcher> createState() => _InactivityWatcherState();
}

class _InactivityWatcherState extends State<InactivityWatcher> {
  Timer? _timer;
  late final BiometricService _verifier;
  bool _locked = false, _busy = false, _supported = false;
  final _password = TextEditingController();
  bool _passwordWrong = false;
  bool _confirmLogout = false, _logoutFailed = false;
  AppUser? _owner;
  String? _origin;
  int? _revision;

  @override
  void initState() {
    super.initState();
    _verifier = widget.verifier ?? BiometricService();
    unawaited(_checkSupport());
    if (widget.enabled) {
      _resetTimer();
    }
  }

  @override
  void didUpdateWidget(InactivityWatcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timeout != widget.timeout ||
        oldWidget.enabled != widget.enabled) {
      if (!widget.enabled && _locked) {
        setState(() => _locked = false);
      }
      _resetTimer();
    }
  }

  Future<void> _checkSupport() async {
    final supported = await _verifier.supportsDeviceUnlock;
    if (mounted) setState(() => _supported = supported);
  }

  /// Fallback when the phone has no PIN/fingerprint: the account password,
  /// checked offline, instead of signing out (which stops monitoring).
  Future<void> _unlockWithPassword(AppState app) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _passwordWrong = false;
    });
    final ok = await app.verifyLockPassword(_password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _locked = false;
        _confirmLogout = false;
        _logoutFailed = false;
        _password.clear();
      } else {
        _passwordWrong = true;
      }
    });
    if (ok) _resetTimer();
  }

  @override
  void dispose() {
    _password.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _resetTimer() {
    _timer?.cancel();
    if (_locked || !widget.enabled) return;
    _timer = Timer(widget.timeout, () {
      if (!mounted || !widget.enabled) return;
      final app = context.read<AppState>();
      if (app.auth.currentUser == null) return;
      if (app.lastAlert?.severity == 'critical' || app.preAlert != null) {
        _resetTimer();
        return;
      }
      setState(() => _locked = true);
    });
  }

  Future<void> _unlock(AppState app) async {
    if (_busy || !_supported) return;
    final owner = app.auth.currentUser;
    final origin = app.api.baseUrl;
    final revision = app.api.tokens.revision;
    final reason = AppLocalizations.of(context).autoLockTitle;
    setState(() => _busy = true);
    final accepted = await _verifier.unlockDevice(reason: reason);
    if (!mounted ||
        !AppUser.sameSessionOwner(owner, app.auth.currentUser) ||
        origin != app.api.baseUrl ||
        revision != app.api.tokens.revision) {
      return;
    }
    setState(() {
      _busy = false;
      if (accepted) {
        _locked = false;
        _confirmLogout = false;
        _logoutFailed = false;
      }
    });
    if (accepted) _resetTimer();
  }

  Future<void> _endSession(AppState app) async {
    if (_busy) return;
    final owner = app.auth.currentUser;
    setState(() {
      _busy = true;
      _logoutFailed = false;
    });
    try {
      await app.signOut();
    } catch (_) {
      if (mounted && AppUser.sameSessionOwner(owner, app.auth.currentUser)) {
        setState(() {
          _busy = false;
          _logoutFailed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!AppUser.sameSessionOwner(_owner, app.auth.currentUser) ||
        _origin != app.api.baseUrl ||
        _revision != app.api.tokens.revision) {
      _owner = app.auth.currentUser;
      _origin = app.api.baseUrl;
      _revision = app.api.tokens.revision;
      _locked = false;
      _busy = false;
      _confirmLogout = false;
      _logoutFailed = false;
      _resetTimer();
    }
    final l = AppLocalizations.of(context);
    final emergency =
        app.lastAlert?.severity == 'critical' || app.preAlert != null;
    return Focus(
      onKeyEvent: (_, _) {
        if (!_locked) _resetTimer();
        return KeyEventResult.ignored;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (!_locked && widget.enabled) _resetTimer();
        },
        onPointerMove: (_) {
          if (!_locked && widget.enabled) _resetTimer();
        },
        onPointerHover: (_) {
          if (!_locked && widget.enabled) _resetTimer();
        },
        child: Stack(
          children: [
            ExcludeSemantics(
              excluding: _locked,
              child: IgnorePointer(ignoring: _locked, child: widget.child),
            ),
            if (_locked)
              Positioned.fill(
                child: Material(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: SafeArea(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 460),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.lock_outline, size: 48),
                              const SizedBox(height: 16),
                              Text(
                                l.autoLockTitle,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                l.isArabic
                                    ? 'قفل الواجهة لا يوقف مهام المراقبة الجارية.'
                                    : 'Locking the screen leaves running monitoring tasks unchanged.',
                                textAlign: TextAlign.center,
                              ),
                              if (emergency) ...[
                                const SizedBox(height: 16),
                                const FirstAidView(),
                              ],
                              const SizedBox(height: 20),
                              if (_supported)
                                FilledButton.icon(
                                  onPressed: _busy ? null : () => _unlock(app),
                                  icon: const Icon(Icons.lock_open),
                                  label: Text(
                                    l.isArabic
                                        ? 'فتح بقفل الجهاز'
                                        : 'Unlock with device security',
                                  ),
                                )
                              else ...[
                                Text(
                                  l.isArabic
                                      ? 'لا يوجد قفل للجهاز. أدخل كلمة مرور حسابك للمتابعة.'
                                      : 'This phone has no screen lock. Enter your account password to continue.',
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _password,
                                  obscureText: true,
                                  enabled: !_busy,
                                  onSubmitted: (_) => _unlockWithPassword(app),
                                  decoration: InputDecoration(
                                    labelText: l.isArabic
                                        ? 'كلمة المرور'
                                        : 'Password',
                                    errorText: _passwordWrong
                                        ? (l.isArabic
                                              ? 'كلمة المرور غير صحيحة.'
                                              : 'Incorrect password.')
                                        : null,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                FilledButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _unlockWithPassword(app),
                                  icon: const Icon(Icons.lock_open),
                                  label: Text(l.isArabic ? 'فتح' : 'Unlock'),
                                ),
                              ],
                              const SizedBox(height: 12),
                              if (_logoutFailed)
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    l.isArabic
                                        ? 'تعذر إنهاء الجلسة. أعد المحاولة.'
                                        : 'Could not end the session. Try again.',
                                  ),
                                ),
                              if (_confirmLogout) ...[
                                Text(
                                  l.isArabic ? 'تسجيل الخروج؟' : 'Sign out?',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                Text(
                                  l.isArabic
                                      ? 'ستتوقف مهام هذا الحساب على الجهاز، وتحتاج إلى الدخول مجددًا. دون اتصال لا يمكن تأكيد إلغاء الجلسة على الخادم. بياناتك المحلية لا تُحذف.'
                                      : 'This ends account tasks on this device and requires signing in again. Offline server revocation cannot be confirmed. Local data is retained.',
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => setState(
                                              () => _confirmLogout = false,
                                            ),
                                      child: Text(
                                        l.isArabic ? 'البقاء' : 'Stay',
                                      ),
                                    ),
                                    FilledButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _endSession(app),
                                      child: Text(l.logout),
                                    ),
                                  ],
                                ),
                              ] else
                                OutlinedButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => setState(
                                          () => _confirmLogout = true,
                                        ),
                                  icon: const Icon(Icons.logout),
                                  label: Text(l.logout),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
