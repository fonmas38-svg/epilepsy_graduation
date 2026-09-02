import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';

enum ReportFilterType { all, seizures, alerts, medications }

/// Comprehensive Medical Reports & Analytics Screen.
///
/// Provides multi-dimensional filtering across time horizons, severity levels,
/// and clinical event categories, with native Excel (.xlsx) and PDF export.
class MedicalReportsScreen extends StatefulWidget {
  const MedicalReportsScreen({
    super.key,
    this.patientId,
    this.patientName,
  });

  final String? patientId;
  final String? patientName;

  @override
  State<MedicalReportsScreen> createState() => _MedicalReportsScreenState();
}

class _MedicalReportsScreenState extends State<MedicalReportsScreen> {
  ReportFilterType _filterType = ReportFilterType.all;
  bool _isExporting = false;

  String _effectivePatientId(AppState app) =>
      widget.patientId ?? app.activePatientId ?? app.auth.currentUser?.uid ?? '';

  String _effectivePatientName(AppState app) =>
      widget.patientName ?? app.auth.currentUser?.name ?? 'المريض';

  Future<void> _exportExcel(BuildContext context) async {
    final app = context.read<AppState>();
    final l = AppLocalizations.of(context);
    final pid = _effectivePatientId(app);
    final pname = _effectivePatientName(app);
    setState(() => _isExporting = true);

    try {
      final alerts = await app.db.alertsFor(pid);
      final events = await app.db.predictionEventsFor(pid);
      final meds = await app.db.medicationsFor(pid);

      final file = await app.reportExporter.exportToExcel(
        patientName: pname,
        patientId: pid,
        alerts: alerts,
        events: events,
        medications: meds,
        l: l,
      );

      if (context.mounted) {
        AppSnack.success(context, 'تم تصدير ملف الإكسل بنجاح: ${file.path.split(RegExp(r'[\\/]')).last}');
      }
    } catch (e) {
      if (context.mounted) {
        AppSnack.error(context, 'فشل تصدير ملف الإكسل: $e');
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(l.reportsTitle),
        actions: [
          IconButton(
            tooltip: l.exportExcel,
            icon: _isExporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.table_view_outlined),
            onPressed: _isExporting ? null : () => _exportExcel(context),
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          final pid = _effectivePatientId(app);
          final pname = _effectivePatientName(app);
          return FutureBuilder<List<dynamic>>(
            future: Future.wait([
              app.db.alertsFor(pid),
              app.db.predictionEventsFor(pid),
              app.db.medicationsFor(pid),
            ]),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final alerts = (snapshot.data?[0] as List<AlertItem>?) ?? const [];
              final events = (snapshot.data?[1] as List<PredictionEvent>?) ?? const [];
              final meds = (snapshot.data?[2] as List<Medication>?) ?? const [];

              return ListView(
                padding: const EdgeInsets.all(Gap.md),
                children: [
                  _buildSummaryHeader(context, alerts, events, meds, pname),
                  const SizedBox(height: Gap.md),
                  _buildFilterChips(context),
                  const SizedBox(height: Gap.md),
                  _buildEventList(context, alerts, events, meds),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSummaryHeader(
    BuildContext context,
    List<AlertItem> alerts,
    List<PredictionEvent> events,
    List<Medication> meds,
    String patientName,
  ) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final escalated = events.where((e) => e.outcome == 'escalated').length;
    final falseAlarms = events.where((e) => e.outcome == 'cancelled_false_alarm').length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics_outlined, size: 26),
                const SizedBox(width: Gap.sm),
                Text(
                  'ملخص مؤشرات الحالة — $patientName',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(height: Gap.lg),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                _buildMetricBadge(
                  context,
                  label: 'إجمالي التنبيهات',
                  value: '${alerts.length}',
                  view: RiskView.danger,
                ),
                _buildMetricBadge(
                  context,
                  label: 'تنبؤات مصعدة',
                  value: '$escalated',
                  view: RiskView.danger,
                ),
                _buildMetricBadge(
                  context,
                  label: 'إنذارات كاذبة ملغاة',
                  value: '$falseAlarms',
                  view: RiskView.caution,
                ),
                _buildMetricBadge(
                  context,
                  label: 'أدوية مجدولة',
                  value: '${meds.length}',
                  view: RiskView.safe,
                ),
              ],
            ),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              onPressed: _isExporting ? null : () => _exportExcel(context),
              icon: const Icon(Icons.file_download_outlined),
              label: Text(l.exportExcel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricBadge(
    BuildContext context, {
    required String label,
    required String value,
    required RiskView view,
  }) {
    final color = AppColors.of(context, view).foreground;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500),
          ),
          Text(
            value,
            style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips(BuildContext context) {
    final l = AppLocalizations.of(context);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          FilterChip(
            selected: _filterType == ReportFilterType.all,
            label: Text(l.filterAll),
            onSelected: (_) => setState(() => _filterType = ReportFilterType.all),
          ),
          const SizedBox(width: Gap.xs),
          FilterChip(
            selected: _filterType == ReportFilterType.alerts,
            label: Text(l.filterAlerts),
            onSelected: (_) => setState(() => _filterType = ReportFilterType.alerts),
          ),
          const SizedBox(width: Gap.xs),
          FilterChip(
            selected: _filterType == ReportFilterType.seizures,
            label: Text(l.filterSeizures),
            onSelected: (_) => setState(() => _filterType = ReportFilterType.seizures),
          ),
          const SizedBox(width: Gap.xs),
          FilterChip(
            selected: _filterType == ReportFilterType.medications,
            label: Text(l.filterMedications),
            onSelected: (_) => setState(() => _filterType = ReportFilterType.medications),
          ),
        ],
      ),
    );
  }

  Widget _buildEventList(
    BuildContext context,
    List<AlertItem> alerts,
    List<PredictionEvent> events,
    List<Medication> meds,
  ) {
    if (_filterType == ReportFilterType.medications) {
      if (meds.isEmpty) return const EmptyState(title: 'لا توجد أدوية مسجلة');
      return Column(
        children: meds
            .map(
              (m) => Card(
                child: ListTile(
                  leading: const Icon(Icons.medication_outlined),
                  title: Text(m.name),
                  subtitle: Text('${m.dosage} · ${m.schedule}'),
                ),
              ),
            )
            .toList(),
      );
    }

    if (alerts.isEmpty && events.isEmpty) {
      return const EmptyState(title: 'لا توجد سجلات تطابق الفلتر المحدد');
    }

    return Column(
      children: alerts
          .map(
            (a) => Card(
              child: ListTile(
                leading: Icon(
                  a.severity == 'critical'
                      ? Icons.warning_amber_rounded
                      : Icons.notifications_active_outlined,
                  color: a.severity == 'critical'
                      ? AppColors.of(context, RiskView.danger).foreground
                      : AppColors.of(context, RiskView.caution).foreground,
                ),
                title: Text(a.message),
                subtitle: Text(a.timestamp.toLocal().toString().split('.')[0]),
              ),
            ),
          )
          .toList(),
    );
  }
}
