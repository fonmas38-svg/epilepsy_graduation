import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';

/// Illustrated seizure first aid, shared by the patient's emergency plan (§3.5)
/// and the family member's response screen (§4.2).
///
/// Deliberately a pure, context-only widget: no provider, no service, no
/// network. Whoever reads this is standing over someone having a seizure, so it
/// must render identically with the radio off — and every step is an icon *plus*
/// a sentence, never an icon alone (§7).
class FirstAidView extends StatelessWidget {
  const FirstAidView({super.key, this.compact = false});

  /// Drops the section frame, for embedding in a screen that already has one.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final body = _Steps(l: l);
    if (compact) return body;
    return SectionCard(
      title: l.firstAidTitle,
      icon: Icons.health_and_safety_outlined,
      child: body,
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.l});

  final AppLocalizations l;

  @override
  Widget build(BuildContext context) {
    final steps = <(IconData, String)>[
      (Icons.timer_outlined, l.firstAid1),
      (Icons.do_not_touch_outlined, l.firstAid2),
      (Icons.bed_outlined, l.firstAid3),
      (Icons.rotate_left_outlined, l.firstAid4),
      (Icons.air_outlined, l.firstAid5),
    ];
    final donts = <String>[l.firstAidDont1, l.firstAidDont2];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          _Step(
            index: i + 1,
            icon: steps[i].$1,
            text: steps[i].$2,
            view: RiskView.safe,
          ),
          if (i != steps.length - 1) Gap.vSm,
        ],
        Gap.vMd,
        Text(
          l.firstAidDont,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: AppColors.of(context, RiskView.danger).foreground,
            fontWeight: FontWeight.w800,
          ),
        ),
        Gap.vSm,
        for (final d in donts) ...[
          _Step(icon: Icons.block_outlined, text: d, view: RiskView.danger),
          Gap.vXs,
        ],
        Gap.vSm,
        InfoNote(
          text: l.firstAidCallAmbulance,
          icon: Icons.local_hospital_outlined,
          view: RiskView.danger,
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.text,
    required this.view,
    this.index,
  });

  final IconData icon;
  final String text;
  final RiskView view;
  final int? index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context, view);
    // At 200% font scale a 44 dp icon column plus text no longer fits side by
    // side, so the row becomes two lines rather than clipping (§7).
    final stack =
        MediaQuery.textScalerOf(context).scale(1) > A11y.stackAboveTextScale;

    final badge = Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.container,
        borderRadius: Radii.rSm,
        border: Border.all(color: colors.border),
      ),
      child: index == null
          ? Icon(icon, size: 18, color: colors.foreground)
          : Text(
              '$index',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.foreground,
                fontWeight: FontWeight.w800,
              ),
            ),
    );
    final label = Text(text, style: theme.textTheme.bodyMedium);

    if (stack) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [badge, Gap.vXs, label],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [badge, Gap.hSm, Expanded(child: label)],
    );
  }
}
