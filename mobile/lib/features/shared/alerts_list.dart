import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/risk_indicator.dart';
import '../../core/ui/states.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';

/// Display state for one alert row.
///
/// `AlertItem.severity` is a backend string (`critical` / `warning` /
/// `pre_alert` / `info`). It is mapped here rather than in the model so the
/// model stays free of presentation, and an unrecognised severity degrades to
/// «غير معروف» instead of silently rendering as safe (§11.1).
/// Pure risk-view mapping from severity string without requiring Localizations.
RiskView alertRiskView(String raw) => switch (raw.trim().toLowerCase()) {
  'critical' || 'danger' || 'high_risk' => RiskView.danger,
  'warning' || 'watch' => RiskView.caution,
  'pre_alert' || 'prealert' || 'preictal' => RiskView.caution,
  'info' || 'stable' => RiskView.safe,
  _ => RiskView.unknown,
};

({RiskView view, String label}) alertSeverity(String raw, AppLocalizations l) {
  final v = alertRiskView(raw);
  final label = switch (v) {
    RiskView.danger => l.severityCritical,
    RiskView.caution =>
      raw.trim().toLowerCase().contains('pre')
          ? l.severityPreAlert
          : l.severityWarning,
    RiskView.safe => l.severityInfo,
    _ => l.unknown,
  };
  return (view: v, label: label);
}

/// A card for a single alert (§2.4's `AlertCard`).
class AlertCard extends StatelessWidget {
  const AlertCard({
    super.key,
    required this.alert,
    this.onAcknowledge,
    this.onTap,
  });

  final AlertItem alert;

  /// Null hides the acknowledge button — e.g. for a read-only history list.
  final Future<void> Function()? onAcknowledge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final s = alertSeverity(alert.severity, l);
    final colors = AppColors.of(context, s.view);
    final when = TimeAgo.since(alert.timestamp, l);

    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.rMd,
        child: Padding(
          padding: Insets.card,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    AppColors.iconFor(s.view),
                    color: colors.foreground,
                    size: 20,
                  ),
                  Gap.hSm,
                  Expanded(
                    child: RiskBadge(
                      view: s.view,
                      labelOverride: s.label,
                      dense: true,
                    ),
                  ),
                  Text(
                    when,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              Gap.vSm,
              Text(alert.displayMessage, style: theme.textTheme.bodyMedium),
              if (alert.details['forecast_status'] != null) ...[
                Gap.vSm,
                Text(
                  alert.details['forecast_status'] == 'prior_model_forecast'
                      ? (l.isArabic
                            ? 'سُجلت إشارة تنبؤ بحثية قبل الرصد؛ وصول تحذير للمرافق غير مؤكد.'
                            : 'A prior research forecast was recorded; warning delivery is unverified.')
                      : (l.isArabic
                            ? 'لم يوجد إنذار سابق في السجل المتاح؛ اكتمال المراقبة وتأكيد النوبة غير مثبتين.'
                            : 'No prior alert in available history; monitoring completeness and seizure confirmation are unverified.'),
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  '${l.isArabic ? 'مرجع الرصد' : 'Detection reference'}: ${alert.details['assessment_id'] ?? alert.id}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              Gap.vSm,
              Row(
                children: [
                  Expanded(
                    child: Text(
                      alert.acknowledged
                          ? '${l.acknowledged}${alert.acknowledgedBy == null ? '' : ' — ${alert.acknowledgedBy}'}'
                          : TimeAgo.stamp(alert.timestamp),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (!alert.acknowledged && onAcknowledge != null)
                    SizedBox(
                      height: A11y.minTouchTarget,
                      child: TextButton.icon(
                        onPressed: () => onAcknowledge!(),
                        icon: const Icon(Icons.done),
                        label: Text(l.acknowledge),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Scrollable alert list with a real empty state (§2.4's four states).
class AlertsList extends StatelessWidget {
  const AlertsList({
    super.key,
    required this.alerts,
    this.onAcknowledge,
    this.onOpen,
    this.padding = Insets.page,
    this.shrinkWrap = false,
  });

  final List<AlertItem> alerts;
  final Future<void> Function(String id)? onAcknowledge;
  final void Function(AlertItem alert)? onOpen;
  final EdgeInsets padding;

  /// True when embedded inside another scroll view.
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (alerts.isEmpty) {
      return EmptyState(
        title: l.noAlerts,
        body: l.emptyBody,
        icon: Icons.notifications_none_outlined,
        compact: shrinkWrap,
      );
    }
    return ListView.builder(
      padding: padding,
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      itemCount: alerts.length,
      itemBuilder: (context, i) {
        final a = alerts[i];
        return AlertCard(
          alert: a,
          onAcknowledge: onAcknowledge == null
              ? null
              : () => onAcknowledge!(a.id),
          onTap: onOpen == null ? null : () => onOpen!(a),
        );
      },
    );
  }
}
