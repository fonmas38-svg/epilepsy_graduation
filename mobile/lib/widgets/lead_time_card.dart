import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/risk_view.dart';
import '../core/ui/common.dart';
import '../l10n/app_localizations.dart';
import '../models/prediction_state.dart';

/// Live lead-time countdown for the seizure forecast.
///
/// The backend is polled every few seconds, so a raw «~15 دقيقة» would sit
/// frozen and then jump. This interpolates locally once per second between polls
/// so the number stays truthful in between.
///
/// One second is the fastest anything in this app is allowed to change: §7
/// forbids fast animation and flashing outright, so the text is re-rendered
/// without any transition, and nothing here fades, slides or pulses.
class LeadTimeCard extends StatefulWidget {
  const LeadTimeCard({super.key, required this.prediction});

  final PredictionState prediction;

  @override
  State<LeadTimeCard> createState() => _LeadTimeCardState();
}

class _LeadTimeCardState extends State<LeadTimeCard> {
  Timer? _timer;

  /// Remaining lead time in seconds, interpolated locally between polls.
  double? _remainingSec;

  @override
  void initState() {
    super.initState();
    _syncFrom(widget.prediction);
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant LeadTimeCard old) {
    super.didUpdateWidget(old);
    // A fresh poll resets the interpolation anchor.
    if (widget.prediction.leadTimeMin != old.prediction.leadTimeMin ||
        widget.prediction.preictalProb != old.prediction.preictalProb) {
      _syncFrom(widget.prediction);
      _restartTimer();
    }
  }

  void _syncFrom(PredictionState p) {
    final min = p.leadTimeMin;
    _remainingSec = min == null
        ? null
        : (min * 60).clamp(0, 24 * 3600).toDouble();
  }

  /// No lead time ⇒ no timer. A ticker that only recomputes the same `null`
  /// would wake the whole subtree once a second for nothing.
  void _restartTimer() {
    _timer?.cancel();
    if (_remainingSec == null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _decay());
  }

  void _decay() {
    final current = _remainingSec;
    if (current == null) return;
    if (current <= 0) {
      _timer?.cancel();
      return;
    }
    setState(() {
      _remainingSec = (current - 1).clamp(0, 24 * 3600).toDouble();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _countdown(AppLocalizations l) {
    final s = _remainingSec;
    if (s == null) return l.notSet;
    if (s <= 0) return l.justNow;
    final totalMin = s / 60.0;
    if (totalMin >= 1) {
      final n = totalMin >= 10
          ? '${totalMin.round()}'
          : totalMin.toStringAsFixed(1);
      return l.minutesApprox(n);
    }
    return '~${s.round()} ${l.secondsUnit}';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final p = widget.prediction;
    // «تنبيه مبكر» is a danger surface; a mere forecast readout is not.
    final view = p.predicted ? RiskView.danger : RiskView.caution;
    final colors = AppColors.of(context, view);

    return SectionCard(
      title: p.predicted ? l.severityPreAlert : l.leadTime,
      icon: p.predicted
          ? Icons.notification_important_outlined
          : Icons.timer_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: '${l.leadTime} ${_countdown(l)}',
            child: ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Icon(
                    AppColors.iconFor(view),
                    size: 18,
                    color: colors.foreground,
                  ),
                  Gap.hSm,
                  Flexible(
                    child: Text(
                      _countdown(l),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: colors.foreground,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (p.horizonMin != null) ...[
            Gap.vSm,
            LabeledValue(
              label: l.horizonTitle,
              value: '${p.horizonMin!.toStringAsFixed(0)} ${l.minutesUnit}',
              icon: Icons.schedule_outlined,
            ),
          ],
        ],
      ),
    );
  }
}
