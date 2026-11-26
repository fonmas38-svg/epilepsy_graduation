import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/enums.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../core/errors/failure.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import '../../services/report_selection.dart';

class MedicalReportsScreen extends StatefulWidget {
  const MedicalReportsScreen({super.key, this.patientId, this.patientName});
  final String? patientId;
  final String? patientName;
  @override
  State<MedicalReportsScreen> createState() => _MedicalReportsScreenState();
}

class _MedicalReportsScreenState extends State<MedicalReportsScreen> {
  String? _patientId;
  String? _owner;
  Future<ReportSelection>? _data;
  ReportCategory _category = ReportCategory.all;
  int _days = 7;
  bool _exporting = false;
  final _anchor = DateTime.now();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppState>();
    if (_owner != app.auth.currentUser?.uid) {
      _owner = app.auth.currentUser?.uid;
      final allowed = app.auth.accessiblePatients();
      final requested = widget.patientId ?? app.activePatientId;
      _patientId = allowed.any((p) => p.patientId == requested)
          ? requested
          : allowed.length == 1
          ? allowed.first.patientId
          : null;
      _data = _load();
    }
  }

  Future<ReportSelection> _load() async {
    final app = context.read<AppState>();
    final pid = _patientId;
    if (pid == null ||
        !app.auth.accessiblePatients().any((p) => p.patientId == pid)) {
      return const ReportSelection(alerts: [], events: [], medications: []);
    }
    final alerts = await app.db.alertsFor(
      pid,
      limit: 10000,
      serverOrigin: app.dataOrigin,
    );
    final events = await app.db.predictionEventsFor(
      pid,
      limit: 10000,
      serverOrigin: app.dataOrigin,
    );
    final meds = await app.db.medicationsFor(pid);
    return ReportSelection(alerts: alerts, events: events, medications: meds);
  }

  ReportSelection _selected(ReportSelection data) => ReportSelection.filter(
    patientId: _patientId!,
    category: _category,
    alerts: data.alerts,
    events: data.events,
    medications: data.medications,
    since: _days == 0 ? null : _anchor.subtract(Duration(days: _days)),
  );

  Future<void> _export(ReportSelection selected) async {
    final app = context.read<AppState>();
    final pid = _patientId;
    final profile = pid == null ? null : app.auth.patientById(pid);
    if (profile == null ||
        app.auth.currentUser?.uid != _owner ||
        !app.auth.accessiblePatients().any((p) => p.patientId == pid)) {
      return;
    }
    setState(() => _exporting = true);
    final l = AppLocalizations.of(context);
    try {
      final file = await app.reportExporter.exportToExcel(
        patientName: profile.name,
        patientId: pid!,
        alerts: selected.alerts,
        events: selected.events,
        medications: selected.medications,
        l: l,
      );
      if (mounted && app.auth.currentUser?.uid == _owner) {
        AppSnack.success(
          context,
          '${l.isArabic ? 'حُفظ التقرير' : 'Report saved'}: ${file.path}',
        );
      }
    } catch (_) {
      if (mounted) AppSnack.error(context, l.exportFailed);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l = AppLocalizations.of(context);
    final ar = l.isArabic;
    final patients = app.auth.accessiblePatients();
    final allowed = patients.any((p) => p.patientId == _patientId);
    final name = allowed ? app.auth.patientById(_patientId!)!.name : null;
    return Scaffold(
      appBar: AppBar(title: Text(l.reportsTitle)),
      body: ResponsiveContent(
        maxWidth: 960,
        child: FutureBuilder<ReportSelection>(
          future: _data,
          builder: (context, snapshot) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                ar ? 'تقرير المريض' : 'Patient report',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              if (patients.isEmpty)
                EmptyState(
                  title: ar ? 'لا يوجد مريض متاح' : 'No accessible patient',
                ),
              if (patients.isNotEmpty) ...[
                if (app.auth.currentUser?.role == UserRole.patient ||
                    patients.length <= 1)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        width: 1.2,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x06000000),
                          blurRadius: 8,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.accent(
                              context,
                              AccentTone.blue,
                            ).container,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.person_rounded,
                            size: 22,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ar
                                    ? 'ملف المريض المصرح له'
                                    : 'Authorized Patient Profile',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                name ?? (ar ? 'ملفي الشخصي' : 'My Profile'),
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.accent(
                              context,
                              AccentTone.green,
                            ).container,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: AppColors.of(
                                context,
                                RiskView.safe,
                              ).border,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.lock_outline,
                                size: 13,
                                color: AppColors.accent(
                                  context,
                                  AccentTone.green,
                                ).foreground,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                ar ? 'خاص ومحمي' : 'Private & Secure',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.accent(
                                    context,
                                    AccentTone.green,
                                  ).foreground,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: allowed ? _patientId : null,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: ar ? 'المريض' : 'Patient',
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                    items: patients
                        .map(
                          (p) => DropdownMenuItem(
                            value: p.patientId,
                            child: Text(p.name),
                          ),
                        )
                        .toList(),
                    onChanged: _exporting
                        ? null
                        : (value) => setState(() {
                            _patientId = value;
                            _data = _load();
                          }),
                  ),
              ],
              const SizedBox(height: 16),
              InfoNote(
                text: ar
                    ? 'هذا التقرير من بيانات الجهاز وقد يكون غير مكتمل. التنبيهات ومخرجات النموذج ليست نوبات مؤكدة. الأدوية تمثل القائمة الحالية، لا سجلًا تاريخيًا للفترة.'
                    : 'This device report may be incomplete. Alerts and model outputs are not confirmed seizures. Medication is the current list, not a historical record for the period.',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ReportCategory.values.map((category) {
                  final label = switch (category) {
                    ReportCategory.all => ar ? 'الكل' : 'All',
                    ReportCategory.alerts => ar ? 'التنبيهات' : 'Alerts',
                    ReportCategory.predictions =>
                      ar ? 'أحداث النموذج' : 'Model events',
                    ReportCategory.medications => ar ? 'الأدوية' : 'Medication',
                  };
                  return ChoiceChip(
                    label: Text(label),
                    selected: _category == category,
                    onSelected: _exporting
                        ? null
                        : (_) => setState(() => _category = category),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _days,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: ar ? 'فترة الأحداث' : 'Event period',
                ),
                items: [7, 30, 0]
                    .map(
                      (days) => DropdownMenuItem(
                        value: days,
                        child: Text(
                          days == 0
                              ? (ar ? 'كل المحفوظ محليًا' : 'All local records')
                              : (ar ? 'آخر $days يومًا' : 'Last $days days'),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _exporting
                    ? null
                    : (value) => setState(() => _days = value ?? 7),
              ),
              const SizedBox(height: 20),
              if (!allowed && patients.isNotEmpty)
                EmptyState(
                  title: ar ? 'اختر المريض لعرض سجله' : 'Select a patient',
                ),
              if (allowed &&
                  snapshot.connectionState == ConnectionState.waiting)
                const Center(child: CircularProgressIndicator()),
              if (allowed && snapshot.hasError) ...[
                Text(Failure.from(snapshot.error!).message(l)),
                TextButton(
                  onPressed: () => setState(() => _data = _load()),
                  child: Text(l.refresh),
                ),
              ],
              if (allowed && snapshot.hasData)
                ..._content(_selected(snapshot.data!), name!, ar),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _content(ReportSelection data, String name, bool ar) => [
    const SizedBox(height: 10),
    Text(
      name,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w800,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    ),
    const SizedBox(height: 12),
    Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.accent(context, AccentTone.red).container,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.of(context, RiskView.danger).border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.notifications_active_outlined,
                size: 16,
                color: AppColors.of(context, RiskView.danger).foreground,
              ),
              const SizedBox(width: 6),
              Text(
                '${ar ? 'التنبيهات' : 'Alerts'}: ${data.alerts.length}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.of(context, RiskView.danger).foreground,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.accent(context, AccentTone.orange).container,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFDE68A)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.analytics_outlined,
                size: 16,
                color: AppColors.accent(context, AccentTone.orange).foreground,
              ),
              const SizedBox(width: 6),
              Text(
                '${ar ? 'أحداث النموذج' : 'Model events'}: ${data.events.length}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.accent(
                    context,
                    AccentTone.orange,
                  ).foreground,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.accent(context, AccentTone.blue).container,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFBFDBFE)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.medication_outlined,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '${ar ? 'الأدوية الحالية' : 'Current medication'}: ${data.medications.length}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
    const SizedBox(height: 18),
    SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        onPressed: _exporting ? null : () => _export(data),
        icon: _exporting
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              )
            : const Icon(Icons.download_rounded, size: 20),
        label: Text(
          ar
              ? 'تصدير النتائج المعروضة (Excel)'
              : 'Export shown results (Excel)',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
      ),
    ),
    const SizedBox(height: 20),
    if (data.alerts.isEmpty && data.events.isEmpty && data.medications.isEmpty)
      EmptyState(
        title: ar ? 'لا توجد بيانات تطابق الاختيار' : 'No matching records',
      ),
    ...data.alerts.map(
      (a) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.accent(context, AccentTone.red).container,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.notifications_outlined,
                color: AppColors.of(context, RiskView.danger).foreground,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.displayMessage,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    TimeAgo.stamp(a.timestamp, AppLocalizations.of(context)),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    ...data.events.map(
      (e) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.accent(context, AccentTone.orange).container,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.analytics_outlined,
                color: AppColors.accent(context, AccentTone.orange).foreground,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ar ? 'حدث من النموذج' : 'Model event',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${TimeAgo.stamp(e.firedAt, AppLocalizations.of(context))} · ${_outcome(e.outcome, ar)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    ...data.medications.map(
      (m) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.accent(context, AccentTone.blue).container,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.medication_outlined,
                color: Theme.of(context).colorScheme.primary,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${m.dosage} · ${m.schedule}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  ];
  String _outcome(String value, bool ar) => switch (value) {
    'escalated' =>
      ar ? 'تم التصعيد، دون تأكيد نوبة' : 'Escalated; seizure unconfirmed',
    'cancelled_false_alarm' => ar ? 'ألغاه المستخدم' : 'Cancelled by user',
    'onset_confirmed' => ar ? 'سُجّل بدء حدث' : 'Event onset recorded',
    _ => ar ? 'غير محسوم' : 'Unresolved',
  };
}
