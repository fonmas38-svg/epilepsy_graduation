import 'package:flutter/material.dart';

import 'risk_view.dart';

/// One resolved semantic colour set: a foreground that is legible on
/// [container], a [container] fill, and a [border].
@immutable
class RiskColors {
  const RiskColors({
    required this.foreground,
    required this.container,
    required this.border,
    required this.onSolid,
    required this.solid,
  });

  /// Text/icon colour to use on top of [container]. WCAG AA (≥ 4.5:1).
  final Color foreground;

  /// Tinted surface behind [foreground].
  final Color container;

  /// Hairline border, for the non-colour-dependent shape cue.
  final Color border;

  /// Saturated fill for high-emphasis surfaces (the danger banner, SOS button).
  final Color solid;

  /// Text/icon colour legible on [solid].
  final Color onSolid;
}

/// Decorative hue families for icon squircles (no clinical meaning).
enum AccentTone { blue, indigo, red, orange, green, slate }

/// A pastel [container] and a [foreground] legible on it (≥ 4.5:1).
@immutable
class AccentColors {
  const AccentColors(this.container, this.foreground);
  final Color container;
  final Color foreground;
}

/// Semantic palette from `docs/frontend-plan-ar.md` §2.4.
///
/// **The critical rule (§2.4, §7):** colour never carries meaning alone. Every
/// risk state pairs a colour with an icon *and* a text label, because red/green
/// is the worst possible pairing to rely on in a medical app — deuteranopia and
/// protanopia are common enough that a colour-only status is unreadable to a
/// meaningful share of users. [iconFor] exists so that pairing is enforced by
/// the type system's usual pressure: any widget reaching for [of] finds the
/// icon accessor right next to it.
abstract final class AppColors {
  /// Brand seed, unchanged from the previous build so existing screens keep
  /// their identity while the rest of the theme is rebuilt around them.
  static const seed = Color(0xFF0966D9);

  // ---------------------------------------------------------------- light mode
  static const _safeLight = RiskColors(
    foreground: Color(0xFF0B5D3B),
    container: Color(0xFFE3F3EA),
    border: Color(0xFF9AD1B5),
    solid: Color(0xFF0F7A4D),
    onSolid: Color(0xFFFFFFFF),
  );
  static const _cautionLight = RiskColors(
    foreground: Color(0xFF7A4E00),
    container: Color(0xFFFFF3DF),
    border: Color(0xFFE8C173),
    solid: Color(0xFF9A6400),
    onSolid: Color(0xFFFFFFFF),
  );
  static const _dangerLight = RiskColors(
    foreground: Color(0xFF981619),
    container: Color(0xFFFDEAEA),
    border: Color(0xFFEFA9A9),
    solid: Color(0xFFB42318),
    onSolid: Color(0xFFFFFFFF),
  );
  static const _unknownLight = RiskColors(
    foreground: Color(0xFF3F4A5A),
    container: Color(0xFFECEFF3),
    border: Color(0xFFB8C1CE),
    solid: Color(0xFF55617A),
    onSolid: Color(0xFFFFFFFF),
  );

  // ----------------------------------------------------------------- dark mode
  // Dark mode is mandatory (§2.4): a patient opening this app at 3 a.m. must not
  // be hit with a full-brightness white screen. Foregrounds are lightened and
  // desaturated so they stay ≥ 4.5:1 against the dark containers.
  static const _safeDark = RiskColors(
    foreground: Color(0xFF7BE3AE),
    container: Color(0xFF10301F),
    border: Color(0xFF2F6B4B),
    solid: Color(0xFF1E8F5E),
    onSolid: Color(0xFF04160D),
  );
  static const _cautionDark = RiskColors(
    foreground: Color(0xFFFCC366),
    container: Color(0xFF33260A),
    border: Color(0xFF7A5A1C),
    solid: Color(0xFFC98A14),
    onSolid: Color(0xFF1C1204),
  );
  static const _dangerDark = RiskColors(
    foreground: Color(0xFFFF9A92),
    container: Color(0xFF3A1416),
    border: Color(0xFF7E2C2C),
    solid: Color(0xFFD03A2E),
    onSolid: Color(0xFF200705),
  );
  static const _unknownDark = RiskColors(
    foreground: Color(0xFFBCC5D2),
    container: Color(0xFF212832),
    border: Color(0xFF49525F),
    solid: Color(0xFF64707F),
    onSolid: Color(0xFF0C0F13),
  );

  /// Signal-trace colours (EEG / ECG / motion), per brightness.
  static const eegLight = Color(0xFF0B6E4F);
  static const ecgLight = Color(0xFF1B4965);
  static const motionLight = Color(0xFF9A3412);
  static const eegDark = Color(0xFF57D6A5);
  static const ecgDark = Color(0xFF7FB4DC);
  static const motionDark = Color(0xFFE8955F);

  static RiskColors resolve(RiskView view, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (view) {
      RiskView.safe => dark ? _safeDark : _safeLight,
      RiskView.caution => dark ? _cautionDark : _cautionLight,
      RiskView.danger => dark ? _dangerDark : _dangerLight,
      RiskView.unknown => dark ? _unknownDark : _unknownLight,
    };
  }

  /// Palette for [view] resolved against the ambient theme.
  static RiskColors of(BuildContext context, RiskView view) =>
      resolve(view, Theme.of(context).brightness);

  // ------------------------------------------------------- decorative accents
  // Pastel squircles behind icons (quick actions, menu rows, avatars). These
  // carry no risk meaning, so they live apart from RiskColors. Every pair is
  // ≥ 4.5:1 in both themes (light: design-system §2.3 values; dark: tinted
  // containers with lightened foregrounds), so no screen hardcodes a pastel
  // that turns into a glaring light square in dark mode.
  static const _accentLight = {
    AccentTone.blue: AccentColors(Color(0xFFEBF3FF), Color(0xFF1565C0)),
    AccentTone.indigo: AccentColors(Color(0xFFEEF0FA), Color(0xFF3949AB)),
    AccentTone.red: AccentColors(Color(0xFFFFEEEE), Color(0xFFC62828)),
    AccentTone.orange: AccentColors(Color(0xFFFFF3E0), Color(0xFFA35200)),
    AccentTone.green: AccentColors(Color(0xFFE8F5E9), Color(0xFF2E7D32)),
    AccentTone.slate: AccentColors(Color(0xFFF0F4F8), Color(0xFF455A64)),
  };
  static const _accentDark = {
    AccentTone.blue: AccentColors(Color(0xFF15294A), Color(0xFF8AB8FF)),
    AccentTone.indigo: AccentColors(Color(0xFF1E2347), Color(0xFFAFB8F6)),
    AccentTone.red: AccentColors(Color(0xFF3A1416), Color(0xFFFF9A92)),
    AccentTone.orange: AccentColors(Color(0xFF33260A), Color(0xFFFCC366)),
    AccentTone.green: AccentColors(Color(0xFF10301F), Color(0xFF7BE3AE)),
    AccentTone.slate: AccentColors(Color(0xFF232B36), Color(0xFFBCC5D2)),
  };

  static AccentColors accentResolve(AccentTone tone, Brightness brightness) =>
      (brightness == Brightness.dark ? _accentDark : _accentLight)[tone]!;

  /// Decorative accent for [tone] in the ambient theme.
  static AccentColors accent(BuildContext context, AccentTone tone) =>
      accentResolve(tone, Theme.of(context).brightness);

  /// The icon that must accompany [view]. Half of the «colour + icon + text»
  /// rule — see the class doc.
  static IconData iconFor(RiskView view) => switch (view) {
    RiskView.safe => Icons.verified_user_outlined,
    RiskView.caution => Icons.warning_amber_rounded,
    RiskView.danger => Icons.dangerous_outlined,
    RiskView.unknown => Icons.help_outline,
  };

  static Color signalEeg(Brightness b) =>
      b == Brightness.dark ? eegDark : eegLight;
  static Color signalEcg(Brightness b) =>
      b == Brightness.dark ? ecgDark : ecgLight;
  static Color signalMotion(Brightness b) =>
      b == Brightness.dark ? motionDark : motionLight;
}
