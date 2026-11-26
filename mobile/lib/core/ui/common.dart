import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/risk_view.dart';
import '../../services/connectivity_coordinator.dart';

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
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? theme.colorScheme.surfaceContainerLow : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? theme.colorScheme.outlineVariant
              : const Color(0xFFE4EDF7),
          width: 1.2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isDark
                          ? theme.colorScheme.surfaceContainerHighest
                          : const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, size: 20, color: const Color(0xFF0066FF)),
                  ),
                  Gap.hSm,
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? theme.colorScheme.onSurface
                              : const Color(0xFF0D253C),
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? theme.colorScheme.onSurfaceVariant
                                : const Color(0xFF64748B),
                          ),
                        ),
                      ],
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
        MediaQuery.sizeOf(context).width < 600 ||
        MediaQuery.textScalerOf(context).scale(14) / 14 >
            A11y.stackAboveTextScale;

    final labelWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          Gap.hXs,
        ],
        Flexible(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
                Flexible(child: labelWidget),
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
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tone.border, width: 1.2),
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
    this.waking = false,
    this.mode,
    this.onSyncNow,
  });

  /// Legacy switch used when [mode] is not given.
  final bool visible;

  /// Already-formatted age of the newest data we hold, or null if we hold none.
  final String? lastUpdateLabel;

  /// Items waiting in the outbox, surfaced so a queued action does not look lost.
  final int pendingCount;

  /// True while [ApiClient] is backing off during a Render cold start.
  /// Ignored when [mode] is given.
  final bool waking;

  /// The unified connectivity state. When set it decides visibility and text,
  /// so a phone without internet never shows «waking the server».
  final AppOperatingMode? mode;

  /// Shown as a «sync now» button while the server is reachable and items wait.
  final Future<bool> Function()? onSyncNow;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final effective =
        mode ??
        (waking
            ? AppOperatingMode.wakingServer
            : visible
            ? AppOperatingMode.offlineLocal
            : AppOperatingMode.onlineFull);
    final online = effective == AppOperatingMode.onlineFull;
    if (online && (pendingCount == 0 || onSyncNow == null)) {
      return const SizedBox.shrink();
    }
    final tone = AppColors.of(context, RiskView.unknown);
    final offlineDetail = lastUpdateLabel == null
        ? l.offlineNoData
        : l.offlineSince(lastUpdateLabel!);
    final text = switch (effective) {
      AppOperatingMode.wakingServer => l.wakingCloudServer,
      AppOperatingMode.reconnectingSyncing => l.syncingNow,
      AppOperatingMode.serverUnreachable =>
        mode == null ? offlineDetail : l.serverUnreachableMode,
      AppOperatingMode.offlineLocal =>
        mode == null ? offlineDetail : '${l.offlineLocalMode}\n$offlineDetail',
      AppOperatingMode.onlineFull => '${l.pendingSync} ($pendingCount)',
    };
    final busy =
        effective == AppOperatingMode.wakingServer ||
        effective == AppOperatingMode.reconnectingSyncing;
    final canSync =
        onSyncNow != null &&
        pendingCount > 0 &&
        (effective == AppOperatingMode.onlineFull ||
            effective == AppOperatingMode.serverUnreachable);
    final icon = switch (effective) {
      AppOperatingMode.offlineLocal => Icons.wifi_off_outlined,
      AppOperatingMode.serverUnreachable => Icons.cloud_off_outlined,
      _ => Icons.cloud_upload_outlined,
    };
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
              if (busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: tone.foreground,
                  ),
                )
              else
                Icon(icon, size: 18, color: tone.foreground),
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
              // Online the text already says «pending sync»; no duplicate badge.
              if (pendingCount > 0 && !online)
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
              if (canSync) ...[
                Gap.hSm,
                TextButton(
                  onPressed: () => onSyncNow!(),
                  child: Text(l.syncNow),
                ),
              ],
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
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
            Icon(
              icon ?? AppColors.iconFor(view),
              color: tone.onSolid,
              size: 20,
            ),
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

  static void success(BuildContext context, String message) => show(
    context,
    message,
    view: RiskView.safe,
    icon: Icons.check_circle_outline,
  );

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

/// An icon inside a pastel squircle (or circle) whose colours follow the
/// theme: [AppColors.accent] gives a light pastel in light mode and a tinted
/// dark container in dark mode, both ≥ 4.5:1 against the icon.
class ToneIcon extends StatelessWidget {
  const ToneIcon({
    super.key,
    required this.icon,
    required this.tone,
    this.size = 22,
    this.padding = 8,
    this.radius = 10,
    this.circle = false,
    this.dimension,
  });

  final IconData icon;
  final AccentTone tone;
  final double size;
  final double padding;
  final double radius;
  final bool circle;

  /// Fixed square size; otherwise the box wraps the icon plus [padding].
  final double? dimension;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.accent(context, tone);
    return Container(
      width: dimension,
      height: dimension,
      padding: dimension == null ? EdgeInsets.all(padding) : null,
      // Only centre inside a fixed box: an aligned Container without a size
      // expands to all available width (breaks ListTile.leading).
      alignment: dimension == null ? null : Alignment.center,
      decoration: BoxDecoration(
        color: c.container,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(radius),
      ),
      child: Icon(icon, color: c.foreground, size: size),
    );
  }
}
