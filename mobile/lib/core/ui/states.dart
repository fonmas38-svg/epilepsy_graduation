import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../errors/failure.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/risk_view.dart';

/// The four render states every screen must handle — `docs/frontend-plan-ar.md`
/// §8: «الشاشة لا تُعتبر مكتملة إلا إذا غُطّيت حالاتها الأربع».
///
/// They live together, and [AsyncView] composes them, so that "did I handle the
/// empty case?" stops being a question a reviewer has to ask per screen: a
/// screen either goes through [AsyncView] or it is visibly doing something
/// unusual.

// ---------------------------------------------------------------------------
// Empty
// ---------------------------------------------------------------------------

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.title,
    this.body,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.actionLabel,
    this.compact = false,
  });

  final String? title;
  final String? body;
  final IconData icon;
  final VoidCallback? action;
  final String? actionLabel;

  /// Tighter layout for use inside a card rather than a full page.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.all(compact ? Gap.lg : Gap.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: compact ? 32 : 48, color: scheme.onSurfaceVariant),
          Gap.vMd,
          Text(
            title ?? l.emptyTitle,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          // «Data will appear as soon as it arrives» only fits data that
          // arrives; with an action the user fills it in, so say nothing.
          if (body != null || action == null) ...[
            Gap.vXs,
            Text(
              body ?? l.emptyBody,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          if (action != null) ...[
            Gap.vLg,
            FilledButton.tonal(
              onPressed: action,
              child: Text(actionLabel ?? l.add),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

/// Renders a [Failure] as a sentence a patient can act on.
///
/// It reads [Failure.message] and never `debugDetail`, which is how §2.6's «لا
/// رسائل تقنية خام» is enforced structurally rather than by reviewer vigilance.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.failure,
    this.onRetry,
    this.compact = false,
  });

  final Failure failure;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tone = AppColors.of(
      context,
      failure.isConnectivity ? RiskView.unknown : RiskView.caution,
    );
    return Padding(
      padding: EdgeInsets.all(compact ? Gap.lg : Gap.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: tone.container,
              shape: BoxShape.circle,
              border: Border.all(color: tone.border),
            ),
            child: Icon(failure.icon, color: tone.foreground, size: 28),
          ),
          Gap.vMd,
          Text(
            l.errorTitle,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          Gap.vXs,
          Text(
            failure.message(l),
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (onRetry != null && failure.canRetry) ...[
            Gap.vLg,
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(l.retry),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// A **static** placeholder block.
///
/// Deliberately not a shimmer. The usual shimmer is a bright gradient sweeping
/// across the screen once or twice a second; in an app for people with a
/// photosensitivity risk (§7) that is a repeating luminance change we have no
/// reason to introduce. A flat tinted block communicates «content is coming»
/// just as well and animates nothing.
class LoadingSkeleton extends StatelessWidget {
  const LoadingSkeleton({
    super.key,
    this.height = 16,
    this.width,
    this.radius = Radii.rSm,
  });

  final double height;
  final double? width;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: radius,
      ),
    );
  }
}

/// A few stacked [LoadingSkeleton] lines shaped like a card.
class LoadingSkeletonCard extends StatelessWidget {
  const LoadingSkeletonCard({super.key, this.lines = 3});

  final int lines;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Semantics(
      label: l.loading,
      // The visual placeholder means nothing to a screen reader; the label above
      // carries the state, so hide the decorative blocks from the tree (§7).
      child: ExcludeSemantics(
        child: Card(
          child: Padding(
            padding: Insets.card,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LoadingSkeleton(height: 20, width: 140),
                for (var i = 0; i < lines; i++) ...[
                  Gap.vMd,
                  LoadingSkeleton(width: i.isEven ? null : 200),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-page loading placeholder: a stack of skeleton cards.
class LoadingPage extends StatelessWidget {
  const LoadingPage({super.key, this.cards = 3});

  final int cards;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: Insets.page,
      itemCount: cards,
      separatorBuilder: (context, index) => Gap.vLg,
      itemBuilder: (context, index) => const LoadingSkeletonCard(),
    );
  }
}

// ---------------------------------------------------------------------------
// Composition
// ---------------------------------------------------------------------------

/// Picks one of the four states for you.
///
/// The precedence deserves a note, because it encodes §2.5 rather than the
/// obvious ordering: **stale data beats an error page.** If a request failed for
/// connectivity reasons but we still hold a cached value, we render the data and
/// let the caller show an offline bar above it. Blanking a patient's screen
/// because the network dropped would remove information they already had.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.loading,
    required this.failure,
    required this.value,
    required this.builder,
    this.isEmpty,
    this.onRetry,
    this.skeleton,
    this.emptyTitle,
    this.emptyBody,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyAction,
    this.emptyActionLabel,
    this.compact = false,
  });

  final bool loading;
  final Failure? failure;
  final T? value;
  final Widget Function(BuildContext context, T value) builder;

  /// Whether a non-null [value] should still count as empty (an empty list).
  final bool Function(T value)? isEmpty;

  final VoidCallback? onRetry;
  final Widget? skeleton;
  final String? emptyTitle;
  final String? emptyBody;
  final IconData emptyIcon;
  final VoidCallback? emptyAction;
  final String? emptyActionLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final v = value;

    // 1. Data we already hold wins over a connectivity error (§2.5).
    final canShowStale = v != null && failure?.isConnectivity == true;

    if (failure != null && !canShowStale) {
      return ErrorState(failure: failure!, onRetry: onRetry, compact: compact);
    }

    if (loading && v == null) {
      return skeleton ??
          (compact ? const LoadingSkeletonCard() : const LoadingPage());
    }

    if (v == null || (isEmpty?.call(v) ?? false)) {
      return EmptyState(
        title: emptyTitle,
        body: emptyBody,
        icon: emptyIcon,
        action: emptyAction,
        actionLabel: emptyActionLabel,
        compact: compact,
      );
    }

    return builder(context, v);
  }
}
