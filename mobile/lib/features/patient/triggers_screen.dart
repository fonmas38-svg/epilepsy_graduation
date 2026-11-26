import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/care_models.dart';
import '../../providers/app_state.dart';

/// Localised label for a stored [TriggerKind].
///
/// The enum's `value` is a stable snake_case key in SQLite and on the wire; the
/// sentence is chosen here so switching language never rewrites stored rows.
String triggerKindLabel(TriggerKind kind, AppLocalizations l) => switch (kind) {
  TriggerKind.sleep => l.triggerSleep,
  TriggerKind.stress => l.triggerStress,
  TriggerKind.fatigue => l.triggerFatigue,
  TriggerKind.missedMeal => l.triggerMeals,
  TriggerKind.menstrual => l.triggerMenstrual,
  TriggerKind.fever => l.triggerFever,
  TriggerKind.missedDose => l.triggerMissedDose,
  TriggerKind.other => l.triggerOther,
};

IconData triggerKindIcon(TriggerKind kind) => switch (kind) {
  TriggerKind.sleep => Icons.bedtime_outlined,
  TriggerKind.stress => Icons.psychology_alt_outlined,
  TriggerKind.fatigue => Icons.self_improvement_outlined,
  TriggerKind.missedMeal => Icons.restaurant_outlined,
  TriggerKind.menstrual => Icons.female_outlined,
  TriggerKind.fever => Icons.thermostat_outlined,
  TriggerKind.missedDose => Icons.medication_outlined,
  TriggerKind.other => Icons.help_outline,
};

/// §3.3 — the trigger diary.
///
/// Two rules shape this screen. First, logging must be fast enough to actually
/// happen: one tap opens the sheet, the kind is a chip, and the time defaults to
/// now. Second, the analysis section states **co-occurrence only** — «لوحظ
/// تزامن», never «سبب» — because n≈1 per patient cannot support a causal claim,
/// and a wrong one here would change how someone takes their medication (§11.4).
class TriggersScreen extends StatelessWidget {
  const TriggersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final care = app.care;
    final triggers = care.triggers;
    final co = care.triggerCoOccurrence();

    return Scaffold(
      appBar: AppBar(title: Text(l.triggersTitle)),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 2,
        onPressed: care.patientId == null
            ? null
            : () => _openSheet(context, app),
        icon: const Icon(Icons.add_rounded),
        label: Text(
          l.addTrigger,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ResponsiveContent(
        maxWidth: 1000,
        child: ListView(
          padding: Insets.pageBottomSafe,
          children: [
            OfflineBanner(
              visible: !app.apiOnline,
              mode: app.operatingMode,
              onSyncNow: app.syncNow,
              lastUpdateLabel: care.lastSyncedAt == null
                  ? null
                  : TimeAgo.since(care.lastSyncedAt, l),
              pendingCount: care.pendingCount,
            ),
            SectionCard(
              title: l.correlationTitle,
              icon: Icons.insights_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InfoNote(text: l.correlationDisclaimer),
                  Gap.vSm,
                  if (co.isEmpty)
                    EmptyState(
                      title: l.emptyTitle,
                      body: l.emptyBody,
                      icon: Icons.query_stats_outlined,
                      compact: true,
                    )
                  else
                    for (final entry in _sorted(co))
                      Padding(
                        padding: const EdgeInsets.only(bottom: Gap.xs),
                        child: LabeledValue(
                          label: triggerKindLabel(entry.key, l),
                          value: l.coOccurrence(entry.value),
                          icon: triggerKindIcon(entry.key),
                        ),
                      ),
                ],
              ),
            ),
            Gap.vMd,
            SectionCard(
              title: l.triggerHistory,
              icon: Icons.edit_note_outlined,
              child: triggers.isEmpty
                  ? EmptyState(
                      title: l.emptyTitle,
                      body: l.emptyBody,
                      icon: Icons.event_note_outlined,
                      compact: true,
                      actionLabel: l.addTrigger,
                      action: care.patientId == null
                          ? null
                          : () => _openSheet(context, app),
                    )
                  : Column(
                      children: [
                        for (final t in triggers)
                          _TriggerRow(
                            entry: t,
                            onDelete: () => _delete(context, app, t),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static List<MapEntry<TriggerKind, int>> _sorted(Map<TriggerKind, int> co) {
    final entries = co.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  Future<void> _delete(
    BuildContext context,
    AppState app,
    TriggerEntry entry,
  ) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.confirmDelete),
        content: Text(triggerKindLabel(entry.kind, l)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await app.care.deleteTrigger(entry);
      if (context.mounted) AppSnack.success(context, l.deleted);
    } catch (_) {
      if (context.mounted) AppSnack.error(context, l.errUnknown);
    }
  }

  Future<void> _openSheet(BuildContext context, AppState app) async {
    final l = AppLocalizations.of(context);
    final result = await showModalBottomSheet<_Draft>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => const _TriggerSheet(),
    );
    if (result == null || !context.mounted) return;
    try {
      await app.care.addTrigger(
        kind: result.kind,
        intensity: result.intensity,
        note: result.note,
      );
      if (!context.mounted) return;
      AppSnack.success(
        context,
        app.apiOnline ? l.triggerLogged : l.savedLocallyWillSync,
      );
    } catch (_) {
      if (context.mounted) AppSnack.error(context, l.errUnknown);
    }
  }
}

class _Draft {
  const _Draft({
    required this.kind,
    required this.intensity,
    required this.note,
  });
  final TriggerKind kind;
  final int intensity;
  final String note;
}

class _TriggerSheet extends StatefulWidget {
  const _TriggerSheet();

  @override
  State<_TriggerSheet> createState() => _TriggerSheetState();
}

class _TriggerSheetState extends State<_TriggerSheet> {
  TriggerKind _kind = TriggerKind.sleep;
  double _intensity = 3;
  final _noteCtrl = TextEditingController();

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: Gap.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.addTrigger, style: theme.textTheme.titleLarge),
              Gap.vMd,
              Text(l.triggerKind, style: theme.textTheme.labelLarge),
              Gap.vXs,
              Wrap(
                spacing: Gap.xs,
                runSpacing: Gap.xs,
                children: [
                  for (final k in TriggerKind.values)
                    ChoiceChip(
                      selected: _kind == k,
                      onSelected: (_) => setState(() => _kind = k),
                      avatar: Icon(triggerKindIcon(k), size: 18),
                      label: Text(triggerKindLabel(k, l)),
                    ),
                ],
              ),
              Gap.vMd,
              Text(
                '${l.triggerIntensity}: ${_intensity.round()}',
                style: theme.textTheme.labelLarge,
              ),
              Slider(
                value: _intensity,
                min: 1,
                max: 5,
                divisions: 4,
                label: '${_intensity.round()}',
                onChanged: (v) => setState(() => _intensity = v),
              ),
              Gap.vSm,
              TextField(
                controller: _noteCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: '${l.triggerNote} (${l.optional})',
                  prefixIcon: const Icon(Icons.note_alt_outlined),
                ),
              ),
              Gap.vLg,
              SizedBox(
                height: A11y.minTouchTarget,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    _Draft(
                      kind: _kind,
                      intensity: _intensity.round(),
                      note: _noteCtrl.text,
                    ),
                  ),
                  icon: const Icon(Icons.save_outlined),
                  label: Text(l.save),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TriggerRow extends StatelessWidget {
  const _TriggerRow({required this.entry, required this.onDelete});

  final TriggerEntry entry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final subtitle = [
      '${l.triggerIntensity} ${entry.intensity}/5',
      TimeAgo.stamp(entry.occurredAt),
      if (!entry.synced) l.pendingSync,
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerHighest
            : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? theme.colorScheme.outlineVariant
              : Theme.of(context).colorScheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              triggerKindIcon(entry.kind),
              color: const Color(0xFFD97706),
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  triggerKindLabel(entry.kind, l),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? theme.colorScheme.onSurface
                        : const Color(0xFF0D253C),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (entry.note.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    entry.note,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? theme.colorScheme.onSurfaceVariant
                          : const Color(0xFF334155),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: l.delete,
            onPressed: onDelete,
            icon: Icon(
              Icons.delete_outline_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}
