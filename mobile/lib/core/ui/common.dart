import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/risk_view.dart';

/// A titled card. Used everywhere so section headings share one type scale and
/// one padding, instead of each screen inventing its own.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
    this.subtitle,
    this.padding = Insets.card,
  });

  final String title;
  final Widget child;
  final IconData? icon;
  final Widget? trailing;
  final String? subtitle;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: theme.colorScheme.primary),
                  Gap.hSm,
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            Gap.vMd,
            child,
          ],
        ),
      ),
    );
  }
}

/// Key–value row that stacks vertically once the text scale gets large, so a
/// 200% font size wraps instead of clipping (§7).
class LabeledValue extends StatelessWidget {
  const LabeledValue({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.icon,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stack =
        MediaQuery.textScalerOf(context).scale(14) / 14 >
        A11y.stackAboveTextScale;

    final labelWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          Gap.hXs,
        ],
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final valueWidget = Text(
      value,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: valueColor,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: stack
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelWidget, Gap.vXxs, valueWidget],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                labelWidget,
                Gap.hSm,
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: valueWidget,
                  ),
                ),
              ],
            ),
    );
  }
}

/// Neutral explanatory note. Used for the honesty disclaimers the plan requires
/// (§3.3 correlation-not-cause, §5.4 no-auto-retraining, §3.5 works-offline).
class InfoNote extends StatelessWidget {
  const InfoNote({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.view = RiskView.unknown,
  });

  final String text;
  final IconData icon;

  /// Tone. `caution` for anything the user could act on wrongly.
  final RiskView view;

  @override
  Widget build(BuildContext context) {
    final tone = AppColors.of(context, view);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: Radii.rSm,
        border: Border.all(color: tone.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: tone.foreground),
          Gap.hSm,
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: tone.foreground,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// «غير متصل — آخر تحديث قبل X» (§2.5).
///
/// A bar, not a dialog: it must not block the emergency actions underneath it.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({
    super.key,
    required this.visible,
    this.lastUpdateLabel,
    this.pendingCount = 0,
  });

  final bool visible;

  /// Already-formatted age of the newest data we hold, or null if we hold none.
  final String? lastUpdateLabel;

  /// Items waiting in the outbox, surfaced so a queued action does not look lost.
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final tone = AppColors.of(context, RiskView.unknown);
    final text = lastUpdateLabel == null
        ? l.offlineNoData
        : l.offlineSince(lastUpdateLabel!);
    return Material(
      color: tone.container,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.lg,
            vertical: Gap.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.wifi_off_outlined, size: 18, color: tone.foreground),
              Gap.hSm,
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    color: tone.foreground,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              if (pendingCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Gap.sm,
                    vertical: Gap.xxs,
                  ),
                  decoration: BoxDecoration(
                    color: tone.solid,
                    borderRadius: Radii.rPill,
                  ),
                  child: Text(
                    '${l.pendingSync} ($pendingCount)',
                    style: TextStyle(color: tone.onSolid, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The «أحتاج مساعدة» control (§3.1: «كبير، ظاهر دائمًا»).
///
/// [A11y.emergencyTouchTarget] tall rather than the 48 dp floor: the person
/// pressing it may have an aura, blurred vision, or shaking hands.
class EmergencyButton extends StatelessWidget {
  const EmergencyButton({
    super.key,
    required this.onPressed,
    this.busy = false,
    this.label,
  });

  final VoidCallback? onPressed;
  final bool busy;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tone = AppColors.of(context, RiskView.danger);
    final text = label ?? l.needHelp;
    return Semantics(
      button: true,
      enabled: onPressed != null && !busy,
      label: text,
      child: ExcludeSemantics(
        child: SizedBox(
          width: double.infinity,
          height: A11y.emergencyTouchTarget,
          child: FilledButton.icon(
            onPressed: busy ? null : onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: tone.solid,
              foregroundColor: tone.onSolid,
              disabledBackgroundColor: tone.solid.withValues(alpha: 0.6),
              disabledForegroundColor: tone.onSolid,
              shape: const RoundedRectangleBorder(borderRadius: Radii.rMd),
              textStyle: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            icon: busy
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: tone.onSolid,
                    ),
                  )
                : const Icon(Icons.emergency_share_outlined, size: 26),
            label: Text(text),
          ),
        ),
      ),
    );
  }
}

/// SnackBars with one consistent tone per outcome.
abstract final class AppSnack {
  static void show(
    BuildContext context,
    String message, {
    RiskView view = RiskView.unknown,
    IconData? icon,
    SnackBarAction? action,
  }) {
    final tone = AppColors.resolve(view, Theme.of(context).brightness);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: tone.solid,
        content: Row(
          children: [
            Icon(icon ?? AppColors.iconFor(view), color: tone.onSolid, size: 20),
            Gap.hSm,
            Expanded(
              child: Text(message, style: TextStyle(color: tone.onSolid)),
            ),
          ],
        ),
        action: action,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  static void success(BuildContext context, String message) =>
      show(context, message, view: RiskView.safe, icon: Icons.check_circle_outline);

  static void info(BuildContext context, String message) =>
      show(context, message, view: RiskView.unknown, icon: Icons.info_outline);

  static void warn(BuildContext context, String message) =>
      show(context, message, view: RiskView.caution);

  static void error(BuildContext context, String message) =>
      show(context, message, view: RiskView.danger, icon: Icons.error_outline);
}

/// Centers content and caps width on tablets and desktop monitors (Windows/macOS/iPad)
/// so layouts do not stretch across wide screens (>850-950dp), while remaining 100%
/// fluid and responsive on mobile phones.
class ResponsiveContent extends StatelessWidget {
  const ResponsiveContent({
    super.key,
    required this.child,
    this.maxWidth = 900,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

