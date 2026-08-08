import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../services/medication_service.dart';

/// Bundles the three things the screen renders so one FutureBuilder drives it.
class _MedData {
  _MedData(this.meds, this.schedule, this.adherence);
  final List<Medication> meds;
  final List<ScheduleEntry> schedule;
  final double adherence;
}

/// Medication-adherence tab (schema v2, additive). Shows today's dose plan with
/// one-tap "taken", a rolling adherence percentage, and add/remove — all backed
/// by the new medication tables only.
class MedicationScreen extends StatefulWidget {
  const MedicationScreen({super.key, required this.patientId});

  final String patientId;

  @override
  State<MedicationScreen> createState() => _MedicationScreenState();
}

class _MedicationScreenState extends State<MedicationScreen> {
  late Future<_MedData> _future;

  MedicationService get _svc => context.read<AppState>().medication;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_MedData> _load() async {
    final meds = await _svc.forPatient(widget.patientId);
    final schedule = await _svc.todaySchedule(widget.patientId);
    final adherence = await _svc.adherence(widget.patientId);
    return _MedData(meds, schedule, adherence);
  }

  void _reload() => setState(() => _future = _load());

  DateTime _todayAt(String hhmm) {
    final parts = hhmm.split(':');
    final now = DateTime.now();
    final h = int.tryParse(parts.first) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return DateTime(now.year, now.month, now.day, h, m);
  }

  Future<void> _markTaken(ScheduleEntry e) async {
    await _svc.markTaken(e.medication, scheduledFor: _todayAt(e.time));
    _reload();
  }

  Future<void> _addDialog() async {
    final nameCtrl = TextEditingController();
    final dosageCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة دواء'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'اسم الدواء'),
            ),
            TextField(
              controller: dosageCtrl,
              decoration: const InputDecoration(labelText: 'الجرعة (مثال: 500mg)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ')),
        ],
      ),
    );
    if (ok == true && nameCtrl.text.trim().isNotEmpty) {
      await _svc.add(
        patientId: widget.patientId,
        name: nameCtrl.text,
        dosage: dosageCtrl.text,
      );
      _reload();
    }
  }

  Future<void> _remove(Medication med) async {
    await _svc.remove(med);
    _reload();
  }

  Color _adherenceColor(double v) => v >= 0.8
      ? const Color(0xFF1B7F4E)
      : v >= 0.5
          ? const Color(0xFFB7791F)
          : const Color(0xFFB42318);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addDialog,
        icon: const Icon(Icons.add),
        label: const Text('دواء'),
      ),
      body: FutureBuilder<_MedData>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _AdherenceCard(value: data.adherence, color: _adherenceColor(data.adherence)),
              const SizedBox(height: 16),
              Text('جرعات اليوم', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (data.schedule.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('لا توجد جرعات مجدولة اليوم.'),
                )
              else
                ...data.schedule.map((e) => _ScheduleTile(entry: e, onTaken: () => _markTaken(e))),
              const SizedBox(height: 20),
              Text('الأدوية', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (data.meds.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('لم تتم إضافة أدوية بعد.'),
                )
              else
                ...data.meds.map((m) => _MedTile(med: m, onDelete: () => _remove(m))),
            ],
          );
        },
      ),
    );
  }
}

class _AdherenceCard extends StatelessWidget {
  const _AdherenceCard({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pct = (value * 100).round();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: value,
                    strokeWidth: 6,
                    backgroundColor: color.withValues(alpha: 0.15),
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                  Text('$pct%', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('الالتزام بالدواء',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('آخر 7 أيام', style: TextStyle(color: Colors.black54)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({required this.entry, required this.onTaken});

  final ScheduleEntry entry;
  final VoidCallback onTaken;

  @override
  Widget build(BuildContext context) {
    final dosage = entry.medication.dosage.isEmpty ? '' : ' · ${entry.medication.dosage}';
    return Card(
      child: ListTile(
        leading: Icon(
          entry.taken ? Icons.check_circle : Icons.schedule,
          color: entry.taken ? const Color(0xFF1B7F4E) : const Color(0xFF1B4965),
        ),
        title: Text('${entry.medication.name}$dosage'),
        subtitle: Text('الساعة ${entry.time}'),
        trailing: entry.taken
            ? const Text('تم', style: TextStyle(color: Color(0xFF1B7F4E)))
            : FilledButton.tonal(onPressed: onTaken, child: const Text('تم الأخذ')),
      ),
    );
  }
}

class _MedTile extends StatelessWidget {
  const _MedTile({required this.med, required this.onDelete});

  final Medication med;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (med.dosage.isNotEmpty) med.dosage,
      if (med.times.isNotEmpty) med.times.join(' · '),
    ].join('  ·  ');
    return ListTile(
      leading: const Icon(Icons.medication_outlined),
      title: Text(med.name),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      ),
    );
  }
}
