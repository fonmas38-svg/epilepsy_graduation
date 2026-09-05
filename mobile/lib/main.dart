import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/config.dart';
import 'core/enums.dart';
import 'core/errors/failure.dart';
import 'core/router/app_router.dart';
import 'core/router/route_names.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_spacing.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/risk_view.dart';
import 'features/auth/login_screen.dart';
import 'features/caregiver/caregiver_home_screen.dart';
import 'features/doctor/doctor_home_screen.dart';
import 'features/onboarding/permissions_onboarding_screen.dart';
import 'features/patient/patient_home_screen.dart';
import 'l10n/app_localizations.dart';
import 'providers/app_state.dart';
import 'widgets/animated_splash_screen.dart';
import 'widgets/inactivity_watcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Filter out known Flutter Windows duplicate Alt-key platform repeat assertion:
  // 'Failed assertion: line 516 pos 11: !_pressedKeys.containsKey(event.physicalKey)'
  FlutterError.onError = (FlutterErrorDetails details) {
    final msg = details.exception.toString();
    final stack = details.stack.toString();
    if (msg.contains('hardware_keyboard.dart') ||
        msg.contains('!_pressedKeys.containsKey') ||
        stack.contains('hardware_keyboard.dart')) {
      debugPrint('Suppressed hardware keyboard platform repeat assertion');
      return;
    }
    FlutterError.presentError(details);
  };

  // FCM is currently an Android-only integration. The Android native config
  // comes from google-services.json, so no generated Dart options file is
  // required for this target. Windows remains usable through backend polling.
  if (!AppConfig.demoMode &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android) {
    try {
      await Firebase.initializeApp();
    } catch (error) {
      // Keep the backend-driven app usable while Firebase client configuration
      // is absent or invalid. NotificationService will skip token registration.
      debugPrint('Firebase initialization skipped: $error');
    }
  }
  final appState = AppState();
  // init() guards its own risky steps, but never let an unexpected failure keep
  // the UI from launching — the login screen must always be reachable.
  try {
    await appState.init();
  } catch (e) {
    appState.failure = Failure.from(e);
    appState.ready = true;
  }
  runApp(EpilepsyApp(appState: appState));
}

class EpilepsyApp extends StatelessWidget {
  const EpilepsyApp({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: appState,
      // Watched here rather than deeper down because theme mode, locale and the
      // role-dependent root all live on MaterialApp itself (§2.1/§2.3/§2.4).
      child: Consumer<AppState>(
        builder: (context, state, _) {
          final router = AppRouter(state);
          return MaterialApp(
            onGenerateTitle: (c) => AppLocalizations.of(c).appTitle,
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            // Dark mode is not optional (§2.4): a patient checking their status
            // at 3 a.m. should not be hit with a white screen.
            themeMode: state.settings.themeMode,
            // Null = follow the device. Arabic is first in supportedLocales, so
            // it is also the fallback for any unsupported system locale (§11.6).
            locale: state.settings.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            navigatorKey: AppRouter.navigatorKey,
            navigatorObservers: [AppRouter.observer],
            onGenerateRoute: router.onGenerateRoute,
            home: const RootShell(),
            // Cap text scaling instead of letting it break the layout, and keep
            // honouring the user's larger sizes up to that cap (§7).
            builder: (context, child) => _AppOverlay(router: router, child: child),
          );
        },
      ),
    );
  }
}

/// Everything that must sit above *every* route: the text-scale clamp, the
/// pre-alert bar and the critical-alert bar.
///
/// The banners live here rather than inside a screen because §3.2 requires the
/// alert to reach the user wherever they are — including on the medication screen
/// or a doctor's patient file. It also owns three cross-cutting jobs that need a
/// context below `MaterialApp`:
///
/// * handing the resolved [AppLocalizations] to [AppState] for the
///   no-context code paths (background pre-alerts),
/// * restoring the last route once, after the first frame (§2.2),
/// * clearing the navigation stack on sign-out, so a pushed screen from the
///   previous session cannot survive into the login screen.
class _AppOverlay extends StatefulWidget {
  const _AppOverlay({required this.router, required this.child});

  final AppRouter router;
  final Widget? child;

  @override
  State<_AppOverlay> createState() => _AppOverlayState();
}

class _AppOverlayState extends State<_AppOverlay> {
  bool _restoreScheduled = false;
  bool _hadSession = false;
  String? _autoOpenedAlertId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l = AppLocalizations.of(context);

    // Safe during build: this only stores a reference and never notifies.
    state.adoptLocalizations(l);

    _syncSession(state);
    _scheduleRestore(state);
    _maybeOpenAlert(state);

    final media = MediaQuery.of(context);
    final scaled = media.textScaler.clamp(maxScaleFactor: A11y.maxTextScale);

    return MediaQuery(
      data: media.copyWith(textScaler: scaled),
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) => Stack(
              children: [
                InactivityWatcher(
                  child: widget.child ?? const SizedBox.shrink(),
                ),
                if (state.preAlert != null)
                  _TopBanner(
                    view: RiskView.caution,
                    icon: Icons.online_prediction,
                    title: state.preAlert!.message,
                    subtitle: 'تنفس بهدوء واسترخِ — اضغط إن كنت بخير لإلغاء التنبيه',
                    action: FilledButton.tonal(
                      onPressed: state.cancelPreAlert,
                      child: Text('أنا بخير (${state.preAlertSecondsLeft})'),
                    ),
                  )
                else if (state.lastAlert != null)
                  _TopBanner(
                    view: RiskView.danger,
                    icon: AppColors.iconFor(RiskView.danger),
                    title: state.lastAlert!.message,
                    subtitle: l.activeAlertTitle,
                    onTap: () => AppRouter.openAlert(
                      alertId: state.lastAlert!.id,
                      patientId: state.lastAlert!.patientId,
                    ),
                    action: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: state.dismissAlertBanner,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Drop any pushed route when the session ends.
  void _syncSession(AppState state) {
    final hasSession = state.auth.currentUser != null;
    if (hasSession == _hadSession) return;
    _hadSession = hasSession;
    if (hasSession) return;
    _restoreScheduled = false;
    _autoOpenedAlertId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = AppRouter.navigatorKey.currentState;
      if (nav != null) {
        nav.pushNamedAndRemoveUntil(Routes.login, (r) => false);
      }
      AppRouter.observer.clearSaved();
    });
  }

  void _scheduleRestore(AppState state) {
    if (_restoreScheduled || !state.ready) return;
    if (state.auth.currentUser == null) return;
    _restoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.router.restore());
  }

  /// Open the full-screen alert view for a new critical alert.
  ///
  /// Patient and family only. A doctor following twenty patients would be thrown
  /// out of whatever they were reading by every one of them; they get the banner,
  /// and their own list already sorts by who needs attention (§5.1).
  void _maybeOpenAlert(AppState state) {
    final alert = state.lastAlert;
    if (alert == null || alert.severity != 'critical') return;
    if (alert.id == _autoOpenedAlertId) return;
    final role = state.auth.currentUser?.role;
    if (role != UserRole.patient && role != UserRole.caregiver) return;
    _autoOpenedAlertId = alert.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppRouter.openAlert(alertId: alert.id, patientId: alert.patientId);
    });
  }
}

/// A floating bar at the top of the screen.
///
/// A bar, not a dialog: §2.5's rule that nothing may block the emergency actions
/// underneath it. Colour is always paired with an icon and text (§2.4).
class _TopBanner extends StatelessWidget {
  const _TopBanner({
    required this.view,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.onTap,
  });

  final RiskView view;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tone = AppColors.of(context, view);
    final theme = Theme.of(context);
    return Positioned(
      left: Gap.md,
      right: Gap.md,
      top: MediaQuery.of(context).padding.top + Gap.sm,
      child: Semantics(
        container: true,
        liveRegion: true,
        label: [title, subtitle].whereType<String>().join('. '),
        child: Material(
          elevation: 6,
          borderRadius: Radii.rMd,
          color: tone.solid,
          child: InkWell(
            onTap: onTap,
            borderRadius: Radii.rMd,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Gap.lg,
                Gap.md,
                Gap.sm,
                Gap.md,
              ),
              child: Row(
                children: [
                  Icon(icon, color: tone.onSolid),
                  Gap.hMd,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: tone.onSolid,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (subtitle != null) ...[
                          Gap.vXxs,
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: tone.onSolid.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (action != null) ...[
                    Gap.hSm,
                    IconTheme(
                      data: IconThemeData(color: tone.onSolid),
                      child: action!,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The role-appropriate root screen.
///
/// This is Guard 1 of §2.2 at the root of the stack: with no session there is no
/// route to a dashboard at all, rather than a dashboard that redirects.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  bool _splashFinished = false;
  bool _onboardingCompleted = true;
  bool _checkedOnboarding = false;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final state = context.read<AppState>();
    final completed = await state.hasCompletedPermissionsOnboarding();
    if (mounted) {
      setState(() {
        _onboardingCompleted = completed;
        _checkedOnboarding = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready || !_splashFinished || !_checkedOnboarding) {
      return AnimatedSplashScreen(
        onFinished: () {
          if (mounted) setState(() => _splashFinished = true);
        },
      );
    }

    if (!_onboardingCompleted) {
      return PermissionsOnboardingScreen(
        onFinished: () {
          if (mounted) setState(() => _onboardingCompleted = true);
        },
      );
    }

    final user = state.auth.currentUser;
    if (user == null) return const LoginScreen();

    return switch (user.role) {
      UserRole.patient => const PatientHomeScreen(),
      UserRole.caregiver => const CaregiverHomeScreen(),
      UserRole.doctor => const DoctorHomeScreen(),
    };
  }
}
