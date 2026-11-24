import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/risk_view.dart';

/// Localised wording for each [RiskView].
///
/// Kept apart from the widgets so the doctor, family and patient surfaces all
/// say the same thing about the same state. Divergent wording across roles is
/// how «آمن» ends up meaning two different things in one system.
abstract final class RiskCopy {
  static String title(RiskView view, AppLocalizations l) => switch (view) {
    RiskView.safe => l.riskSafeTitle,
    RiskView.caution => l.riskCautionTitle,
    RiskView.danger => l.riskDangerTitle,
    RiskView.unknown => l.riskUnknownTitle,
  };

  static String body(
    RiskView view,
    AppLocalizations l, {
    double? leadTimeMin,
  }) => switch (view) {
    RiskView.safe => l.riskSafeBody,
    RiskView.caution => l.riskCautionBody,
    RiskView.danger =>
      leadTimeMin != null && leadTimeMin > 0
          ? l.riskDangerBody(leadTimeMin.round())
          : l.riskDangerBodyNoLead,
    RiskView.unknown => l.riskUnknownBody,
  };

  /// Position of [view] on the 4-step scale, used by [RiskStrip] so severity is
  /// also readable from *where* the filled segment sits — a cue that survives
  /// colour blindness and a greyscale screenshot.
  static int step(RiskView view) => switch (view) {
    RiskView.unknown => 0,
    RiskView.safe => 1,
    RiskView.caution => 2,
    RiskView.danger => 3,
  };
}

/// Compact pill: colour **+ icon + text**, per §2.4's critical rule.
///
/// Replaces the old colour-only `StatusBadge`, which conveyed the level through
/// hue alone.
class RiskBadge extends StatelessWidget {
  const RiskBadge({
    super.key,
    required this.view,
    this.labelOverride,
    this.dense = false,
  });

  final RiskView view;
  final String? labelOverride;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tone = AppColors.of(context, view);
    final label = labelOverride ?? RiskCopy.title(view, l);
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Container(
          padding: dense
              ? const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs)
              : Insets.chip,
          decoration: BoxDecoration(
            color: tone.container,
            borderRadius: Radii.rPill,
            border: Border.all(color: tone.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppColors.iconFor(view),
                size: dense ? 14 : 18,
                color: tone.foreground,
              ),
              SizedBox(width: dense ? Gap.xs : Gap.sm),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: tone.foreground,
                    fontWeight: FontWeight.w700,
                    fontSize: dense ? 12 : 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Four segments; the one matching [view] is filled.
///
/// `unknown` fills the leftmost segment in the neutral grey rather than filling
/// nothing, because an empty strip reads as «no problem» — the exact confusion
/// §3.1 is written to prevent.
class RiskStrip extends StatelessWidget {
  const RiskStrip({super.key, required this.view});

  final RiskView view;

  @override
  Widget build(BuildContext context) {
    final tone = AppColors.of(context, view);
    final scheme = Theme.of(context).colorScheme;
    final active = RiskCopy.step(view);
    return ExcludeSemantics(
      child: Row(
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) Gap.hXs,
            Expanded(
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  color: i == active
                      ? tone.solid
                      : scheme.surfaceContainerHighest,
                  borderRadius: Radii.rPill,
                  border: i == active
                      ? null
                      : Border.all(color: scheme.outlineVariant, width: 0.5),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The «حالتي الآن» hero element (§3.1).
///
/// Everything about it is stated in words: the level, what to do, and how fresh
/// the reading is. Nothing here animates — a status that pulses would be both a
/// photosensitivity hazard (§7) and a source of anxiety on a screen a patient
/// glances at all day.
class RiskGauge extends StatelessWidget {
  const RiskGauge({
    super.key,
    required this.view,
    this.leadTimeMin,
    this.freshnessLabel,
    this.reasonLabel,
    this.trailing,
  });

  final RiskView view;

  /// Minutes of warning, when the forecast layer produced one.
  final double? leadTimeMin;

  /// e.g. «آخر تحديث قبل ٤٠ ثانية».
  final String? freshnessLabel;

  /// Why we are showing `unknown`, shown only for that state.
  final String? reasonLabel;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tone = AppColors.of(context, view);
    final theme = Theme.of(context);
    final title = RiskCopy.title(view, l);
    final body = RiskCopy.body(view, l, leadTimeMin: leadTimeMin);

    return Semantics(
      // One label for the whole card: a screen reader should announce the state
      // as a sentence, not read out three disconnected fragments.
      label: [
        l.myStatusNow,
        title,
        body,
        if (view.isUnknown) ?reasonLabel,
        ?freshnessLabel,
      ].join('. '),
      container: true,
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: Insets.card,
          decoration: BoxDecoration(
            color: tone.container,
            borderRadius: Radii.rMd,
            border: Border.all(
              color: tone.border,
              // A thicker rule for danger, so severity is legible from the shape
              // of the card at arm's length.
              width: view.isCritical ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    AppColors.iconFor(view),
                    color: tone.foreground,
                    size: 32,
                  ),
                  Gap.hMd,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.myStatusNow,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: tone.foreground.withValues(alpha: 0.85),
                          ),
                        ),
                        Text(
                          title,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: tone.foreground,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
              Gap.vMd,
              RiskStrip(view: view),
              Gap.vMd,
              Text(
                body,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: tone.foreground,
                  height: 1.4,
                ),
              ),
              if (view.isUnknown && reasonLabel != null) ...[
                Gap.vXs,
                Text(
                  reasonLabel!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tone.foreground.withValues(alpha: 0.85),
                  ),
                ),
              ],
              if (freshnessLabel != null) ...[
                Gap.vSm,
                Row(
                  children: [
                    Icon(
                      Icons.schedule,
                      size: 14,
                      color: tone.foreground.withValues(alpha: 0.8),
                    ),
                    Gap.hXs,
                    Expanded(
                      child: Text(
                        freshnessLabel!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tone.foreground.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
