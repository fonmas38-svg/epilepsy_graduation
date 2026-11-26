import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_spacing.dart';
import 'risk_view.dart';

/// Motion policy — `docs/frontend-plan-ar.md` §7.
///
/// Photosensitivity is a documented seizure trigger, so this app treats fast or
/// flashing animation as a safety defect, not a style choice. Every animated
/// widget must take its duration from [AppMotion.duration], which collapses to
/// [Duration.zero] when the platform's «reduce motion» setting is on, and is
/// otherwise deliberately slow.
abstract final class AppMotion {
  /// Slow enough that nothing reads as a flash. Used for state changes.
  static const Duration calm = Duration(milliseconds: 320);

  /// For larger surface transitions (page fades).
  static const Duration page = Duration(milliseconds: 260);

  /// Zero when the user asked the OS to reduce motion, otherwise [base].
  static Duration duration(BuildContext context, [Duration base = calm]) {
    return MediaQuery.maybeDisableAnimationsOf(context) == true
        ? Duration.zero
        : base;
  }

  /// A curve with no overshoot. Bouncy/elastic curves are banned here: the
  /// oscillation is exactly the kind of rapid luminance change §7 rules out.
  static const Curve curve = Curves.easeInOut;
}

/// Page transitions restricted to a slow cross-fade on every platform.
///
/// The Material default slides and, on some platforms, briefly darkens the
/// outgoing route. A fade has no directional motion and no flicker, which is
/// what §7 asks for. It also reads correctly under RTL, where a horizontal
/// slide inherited from an LTR default looks backwards.
class _FadePageTransitions extends PageTransitionsBuilder {
  const _FadePageTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) return child;
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: AppMotion.curve),
      child: child,
    );
  }
}

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.seed,
          brightness: brightness,
          // Bind the error role to our danger colour so Material's own error
          // surfaces (TextField validation, etc.) match the risk palette instead of
          // introducing a second, competing red.
          error: AppColors.resolve(RiskView.danger, brightness).solid,
        ).copyWith(
          primary: brightness == Brightness.dark
              ? const Color(0xFF91C0FF)
              : AppColors.seed,
        );
    final dark = brightness == Brightness.dark;

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: brightness,
      // Intentionally no `fontFamily`. The previous build pinned 'Roboto',
      // which carries no Arabic glyphs, forcing every Arabic string through
      // font fallback. Leaving it unset lets the platform pick its Arabic face
      // directly. To adopt Cairo / IBM Plex Sans Arabic (§2.4) bundle the .ttf
      // under mobile/assets/fonts/, declare it in pubspec.yaml, then set
      // `fontFamily: 'Cairo'` here — one line, one place.
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      scaffoldBackgroundColor: dark
          ? const Color(0xFF101A2B)
          : const Color(0xFFF6F9FD),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _FadePageTransitions(),
          TargetPlatform.iOS: _FadePageTransitions(),
          TargetPlatform.windows: _FadePageTransitions(),
          TargetPlatform.macOS: _FadePageTransitions(),
          TargetPlatform.linux: _FadePageTransitions(),
          TargetPlatform.fuchsia: _FadePageTransitions(),
        },
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: dark ? scheme.surface : Colors.white,
        foregroundColor: dark ? scheme.onSurface : const Color(0xFF0D253C),
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: dark ? scheme.onSurface : const Color(0xFF0D253C),
          fontWeight: FontWeight.w800,
          fontSize: 19,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? scheme.surface : Colors.white,
        indicatorColor: scheme.primaryContainer,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: dark ? scheme.surface : Colors.white,
        indicatorColor: scheme.primaryContainer,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: dark ? scheme.outlineVariant : const Color(0xFFE4EDF7),
            width: 1.2,
          ),
        ),
        color: dark ? scheme.surfaceContainerLow : Colors.white,
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: Gap.md,
        contentPadding: Insets.tile,
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: dark ? scheme.outlineVariant : const Color(0xFFE4EDF7),
      ),
      // Every button meets the 48 dp floor from §7 without each call site
      // remembering to ask.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, A11y.minTouchTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          backgroundColor: const Color(0xFF0066FF),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, A11y.minTouchTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          side: BorderSide(
            color: dark ? scheme.outlineVariant : const Color(0xFFE4EDF7),
            width: 1.2,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, A11y.minTouchTarget),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(A11y.minTouchTarget, A11y.minTouchTarget),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: dark ? scheme.surface : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? scheme.surfaceContainerHighest : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: dark ? scheme.outlineVariant : const Color(0xFFE4EDF7),
            width: 1.2,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: dark ? scheme.outlineVariant : const Color(0xFFE4EDF7),
            width: 1.2,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF0066FF), width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Gap.md,
          vertical: Gap.md,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: Radii.rSm),
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: const TextStyle(fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500),
        indicatorSize: TabBarIndicatorSize.tab,
      ),
      chipTheme: ChipThemeData(
        shape: const RoundedRectangleBorder(borderRadius: Radii.rPill),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      dialogTheme: const DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: Radii.rMd),
      ),
      // Progress indicators animate continuously; keep them low-contrast so a
      // spinner is never the brightest thing on a night-time screen.
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearMinHeight: 6,
      ),
    );
  }
}
