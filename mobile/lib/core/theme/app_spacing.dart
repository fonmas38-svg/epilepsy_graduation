import 'package:flutter/widgets.dart';

/// 4-pt spacing scale (`docs/frontend-plan-ar.md` §2.4) plus the accessibility
/// constants the plan makes non-negotiable in §7.
///
/// Everything is `const` so it costs nothing at runtime and can be used in
/// const constructors.
abstract final class Gap {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  // Ready-made vertical/horizontal spacers — cheaper to read than SizedBox
  // literals scattered through build methods.
  static const Widget vXxs = SizedBox(height: xxs);
  static const Widget vXs = SizedBox(height: xs);
  static const Widget vSm = SizedBox(height: sm);
  static const Widget vMd = SizedBox(height: md);
  static const Widget vLg = SizedBox(height: lg);
  static const Widget vXl = SizedBox(height: xl);
  static const Widget vXxl = SizedBox(height: xxl);

  static const Widget hXs = SizedBox(width: xs);
  static const Widget hSm = SizedBox(width: sm);
  static const Widget hMd = SizedBox(width: md);
  static const Widget hLg = SizedBox(width: lg);
}

abstract final class Radii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double pill = 999;

  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius rPill = BorderRadius.all(Radius.circular(pill));
}

abstract final class Insets {
  static const EdgeInsets page = EdgeInsets.all(Gap.lg);
  static const EdgeInsets card = EdgeInsets.all(Gap.lg);
  static const EdgeInsets tile = EdgeInsets.symmetric(
    horizontal: Gap.lg,
    vertical: Gap.md,
  );
  static const EdgeInsets chip = EdgeInsets.symmetric(
    horizontal: Gap.md,
    vertical: Gap.sm,
  );

  /// Bottom padding for scroll views so the last card clears a FAB / nav bar.
  static const EdgeInsets pageBottomSafe = EdgeInsets.fromLTRB(
    Gap.lg,
    Gap.lg,
    Gap.lg,
    Gap.xxxl + Gap.xl,
  );
}

/// Accessibility floors from `docs/frontend-plan-ar.md` §7. These are minimums,
/// not suggestions: an interactive target below [minTouchTarget] fails the
/// plan's acceptance bar.
abstract final class A11y {
  /// Minimum size of any interactive element, in logical pixels (dp).
  static const double minTouchTarget = 48;

  /// The primary emergency action is deliberately far larger than the floor —
  /// it has to be hittable by someone whose hands are shaking.
  static const double emergencyTouchTarget = 72;

  /// Text scale beyond which layouts switch to a stacked/vertical arrangement
  /// instead of overflowing. §7 requires no breakage at 200%.
  static const double stackAboveTextScale = 1.5;

  /// Hard cap applied to the OS text scale. We honour the user's setting up to
  /// 200% (§7) but refuse to render past it, because beyond that the emergency
  /// actions themselves start to clip off-screen.
  static const double maxTextScale = 2.0;
}
