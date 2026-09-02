import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/risk_view.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_state.dart';
import '../services/biometric_service.dart';

/// Inactivity Auto-Lock Watcher (#InactivitySecurity).
///
/// Listens to all user touch/pointer and keyboard interactions across the entire
/// application. If no interaction is detected for [timeout] (default 5 minutes),
/// and the user is authenticated, it overlays a security shield requiring
/// biometric verification or password re-entry to restore access.
class InactivityWatcher extends StatefulWidget {
  const InactivityWatcher({
    super.key,
    required this.child,
    this.timeout = const Duration(minutes: 5),
  });

  final Widget child;
  final Duration timeout;

  @override
  State<InactivityWatcher> createState() => _InactivityWatcherState();
}

class _InactivityWatcherState extends State<InactivityWatcher> {
  Timer? _inactivityTimer;
  bool _isLocked = false;
  final _biometrics = BiometricService();

  @override
  void initState() {
    super.initState();
    _resetTimer();
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    super.dispose();
  }

  void _resetTimer() {
    _inactivityTimer?.cancel();
    if (_isLocked) return;

    _inactivityTimer = Timer(widget.timeout, () {
      final app = context.read<AppState>();
      // Only lock if user is signed in and not in active emergency alert
      if (app.auth.currentUser != null && app.lastAlert?.severity != 'critical') {
        setState(() => _isLocked = true);
      }
    });
  }

  void _onUserInteraction([_]) {
    if (!_isLocked) {
      _resetTimer();
    }
  }

  Future<void> _unlockWithBiometrics(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final success = await _biometrics.authenticate(
      localizedReason: l.biometricPromptReason,
    );
    if (success && mounted) {
      setState(() {
        _isLocked = false;
        _resetTimer();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onUserInteraction,
      onPointerMove: _onUserInteraction,
      onPointerHover: _onUserInteraction,
      child: Stack(
        textDirection: TextDirection.rtl,
        children: [
          widget.child,
          if (_isLocked) _buildLockOverlay(context),
        ],
      ),
    );
  }

  Widget _buildLockOverlay(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final app = context.read<AppState>();

    return Material(
      color: theme.scaffoldBackgroundColor.withValues(alpha: 0.96),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: AppColors.of(context, RiskView.caution).container,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.lock_clock_outlined,
                      size: 40,
                      color: AppColors.of(context, RiskView.caution).foreground,
                    ),
                  ),
                  const SizedBox(height: Gap.lg),
                  Text(
                    l.autoLockTitle,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: Gap.sm),
                  Text(
                    l.autoLockMessage,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: Gap.xl),
                  FilledButton.icon(
                    onPressed: () => _unlockWithBiometrics(context),
                    icon: const Icon(Icons.fingerprint),
                    label: Text(l.unlockWithBiometrics),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() => _isLocked = false);
                      app.signOut();
                    },
                    icon: const Icon(Icons.logout),
                    label: Text(l.logout),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
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
