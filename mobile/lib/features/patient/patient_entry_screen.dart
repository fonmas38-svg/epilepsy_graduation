import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/errors/failure.dart';
import '../../core/router/route_names.dart';
import '../../core/ui/common.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/care_models.dart';
import '../../providers/app_state.dart';

class PatientEntryScreen extends StatelessWidget {
  const PatientEntryScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final ar = AppLocalizations.of(context).isArabic;
    Widget option({
      required IconData icon,
      required Color iconColor,
      required Color iconBgColor,
      required String title,
      required String description,
      required String route,
    }) =>
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => Navigator.pushNamed(context, route),
            borderRadius: BorderRadius.circular(20),
            child: Ink(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE4EDF7), width: 1.2),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x06000000),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: iconBgColor,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: iconColor, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0D253C),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          description,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF64748B),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    ar ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                    color: const Color(0xFF94A3B8),
                    size: 22,
                  ),
                ],
              ),
            ),
          ),
        );

    return Scaffold(
      backgroundColor: const Color(0xFFF6F9FD),
      appBar: AppBar(
        title: Text(
          ar ? 'إضافة سجل' : 'Add a record',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF0D253C),
            fontSize: 19,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF0D253C)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE4EDF7), height: 1),
        ),
      ),
      body: ResponsiveContent(
        maxWidth: 760,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          children: [
            Text(
              ar ? 'ما الذي تريد تسجيله؟' : 'What would you like to record?',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0D253C),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              ar
                  ? 'اختر نوع الإدخال لمتابعة حالتك الصحية وتوثيق الأحداث بدقة.'
                  : 'Choose an entry type to keep your health log up to date.',
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 24),
            option(
              icon: Icons.bolt_rounded,
              iconColor: const Color(0xFFE11D48),
              iconBgColor: const Color(0xFFFFF1F2),
              title: ar ? 'توثيق نوبة تمت ملاحظتها' : 'Document an observed seizure',
              description: ar
                  ? 'وقت الحدث ومدته إن عُرفت، مع ملاحظاتك.'
                  : 'Record the time, known duration and your notes.',
              route: Routes.patientSeizureEntry,
            ),
            const SizedBox(height: 14),
            option(
              icon: Icons.psychology_outlined,
              iconColor: const Color(0xFFD97706),
              iconBgColor: const Color(0xFFFEF3C7),
              title: ar ? 'محفز أو ملاحظة' : 'Trigger or note',
              description: ar
                  ? 'سجّل النوم أو الإجهاد أو ملاحظة أخرى.'
                  : 'Record sleep, stress or another observation.',
              route: Routes.patientTriggers,
            ),
            const SizedBox(height: 14),
            option(
              icon: Icons.medication_rounded,
              iconColor: const Color(0xFF0066FF),
              iconBgColor: const Color(0xFFEFF6FF),
              title: ar ? 'تناول دواء' : 'Medication taken',
              description: ar
                  ? 'اختر الجرعة من جدول الأدوية لتسجيل تناولها.'
                  : 'Choose a scheduled dose to record it as taken.',
              route: Routes.patientMedications,
            ),
          ],
        ),
      ),
    );
  }
}

class SeizureEntryScreen extends StatefulWidget {
  const SeizureEntryScreen({super.key});
  @override
  State<SeizureEntryScreen> createState() => _SeizureEntryScreenState();
}

class _SeizureEntryScreenState extends State<SeizureEntryScreen> {
  final _notes = TextEditingController();
  final _duration = TextEditingController();
  final _form = GlobalKey<FormState>();
  DateTime _occurredAt = DateTime.now();
  SeizureType _type = SeizureType.other;
  bool _busy = false;
  bool _dirty = false;
  bool _leaveAllowed = false;
  bool get ar => AppLocalizations.of(context).isArabic;
  @override
  void dispose() {
    _notes.dispose();
    _duration.dispose();
    super.dispose();
  }

  Future<void> _chooseTime() async {
    final day = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_occurredAt),
    );
    if (time != null && mounted) {
      setState(() {
        _occurredAt = DateTime(
          day.year,
          day.month,
          day.day,
          time.hour,
          time.minute,
        );
        _dirty = true;
      });
    }
  }

  Future<void> _confirmLeave() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          ar ? 'تجاهل السجل غير المحفوظ؟' : 'Discard the unsaved record?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(ar ? 'البقاء' : 'Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(ar ? 'تجاهل' : 'Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _leaveAllowed = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (_occurredAt.isAfter(DateTime.now())) {
      AppSnack.warn(
        context,
        ar
            ? 'اختر وقتًا لا يقع في المستقبل.'
            : 'Choose a time that is not in the future.',
      );
      return;
    }
    final app = context.read<AppState>();
    final user = app.auth.currentUser;
    if (user == null || !app.auth.canAccessPatient(user.uid)) return;
    setState(() => _busy = true);
    try {
      if (app.care.patientId != user.uid) {
        await app.care.loadFor(user.uid, remote: false);
      }
      if (!mounted || !identical(app.auth.currentUser, user)) return;
      await app.care.logSeizure(
        occurredAt: _occurredAt.toUtc(),
        durationSeconds: int.tryParse(_duration.text.trim()),
        type: _type,
        notes: _notes.text.trim(),
        reportedBy: user.uid,
      );
      if (!mounted || !identical(app.auth.currentUser, user)) return;
      setState(() {
        _leaveAllowed = true;
        _dirty = false;
      });
      AppSnack.success(
        context,
        ar
            ? 'حُفظ البلاغ محليًا وأُضيف إلى طابور المزامنة.'
            : 'Report saved locally and added to the synchronization queue.',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
      });
    } catch (error) {
      if (mounted) {
        AppSnack.error(
          context,
          Failure.from(error).message(AppLocalizations.of(context)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && (!_dirty || _leaveAllowed),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _confirmLeave();
    },
    child: Scaffold(
      backgroundColor: const Color(0xFFF6F9FD),
      appBar: AppBar(
        title: Text(
          ar ? 'توثيق حدث' : 'Document an event',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF0D253C),
            fontSize: 19,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF0D253C)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE4EDF7), height: 1),
        ),
      ),
      body: ResponsiveContent(
        maxWidth: 760,
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            children: [
              InfoNote(
                text: ar
                    ? 'هذا بلاغ منك عن حدث تمت ملاحظته، وليس تشخيصًا أو تأكيدًا من النموذج. اترك ما لا تعرفه فارغًا.'
                    : 'This is your report of an observed event, not a diagnosis or model confirmation. Leave unknown details blank.',
              ),
              const SizedBox(height: 20),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _busy ? null : _chooseTime,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE4EDF7), width: 1.2),
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
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.calendar_today_rounded,
                            color: Color(0xFF0066FF),
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ar ? 'وقت وقوع الحدث' : 'Event time',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF64748B),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                TimeAgo.stamp(_occurredAt),
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0D253C),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.edit_calendar_rounded,
                          color: Color(0xFF0066FF),
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _duration,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: ar
                      ? 'المدة بالثواني (اختياري)'
                      : 'Duration in seconds (optional)',
                  labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
                  prefixIcon: const Icon(Icons.timer_outlined, color: Color(0xFF0066FF)),
                  filled: true,
                  fillColor: Colors.white,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFFE4EDF7), width: 1.2),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFF0066FF), width: 1.5),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFFE11D48), width: 1.2),
                  ),
                  focusedErrorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFFE11D48), width: 1.5),
                  ),
                ),
                onChanged: (_) => setState(() => _dirty = true),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  final duration = int.tryParse(value.trim());
                  return duration == null || duration < 1 || duration > 86400
                      ? (ar
                            ? 'أدخل عددًا من 1 إلى 86400، أو اتركه فارغًا.'
                            : 'Enter 1–86400 seconds, or leave blank.')
                      : null;
                },
              ),
              const SizedBox(height: 18),
              DropdownButtonFormField<SeizureType>(
                initialValue: _type,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: ar
                      ? 'النوع المعروف إن وُجد'
                      : 'Known type, if available',
                  labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
                  prefixIcon: const Icon(Icons.bubble_chart_outlined, color: Color(0xFF0066FF)),
                  filled: true,
                  fillColor: Colors.white,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFFE4EDF7), width: 1.2),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFF0066FF), width: 1.5),
                  ),
                ),
                items: SeizureType.values
                    .map(
                      (type) => DropdownMenuItem(
                        value: type,
                        child: Text(switch (type) {
                          SeizureType.other =>
                            ar ? 'غير محدد / أخرى' : 'Unspecified / other',
                          SeizureType.focal => ar ? 'بؤرية' : 'Focal',
                          SeizureType.generalized =>
                            ar ? 'معممة' : 'Generalized',
                          SeizureType.absence => ar ? 'غياب' : 'Absence',
                        }),
                      ),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _type = value ?? SeizureType.other;
                        _dirty = true;
                      }),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _notes,
                enabled: !_busy,
                minLines: 3,
                maxLines: 8,
                maxLength: 2000,
                decoration: InputDecoration(
                  labelText: ar ? 'ملاحظات (اختياري)' : 'Notes (optional)',
                  labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
                  alignLabelWithHint: true,
                  prefixIcon: const Padding(
                    padding: EdgeInsets.only(bottom: 60),
                    child: Icon(Icons.notes_rounded, color: Color(0xFF0066FF)),
                  ),
                  filled: true,
                  fillColor: Colors.white,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFFE4EDF7), width: 1.2),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Color(0xFF0066FF), width: 1.5),
                  ),
                ),
                onChanged: (_) => setState(() => _dirty = true),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0066FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  onPressed: _busy ? null : _save,
                  icon: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check_circle_outline_rounded, size: 20),
                  label: Text(
                    ar ? 'حفظ البلاغ' : 'Save report',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
