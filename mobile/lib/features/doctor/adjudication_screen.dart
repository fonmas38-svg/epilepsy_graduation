import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failure.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/risk_indicator.dart';
import '../../core/ui/states.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/care_models.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../shared/alerts_list.dart';

/// Localised name of a verdict. Public so the patient file shows the same word
/// for the same decision.
String verdictLabel(AdjudicationVerdict v, AppLocalizations l) => switch (v) {
  AdjudicationVerdict.seizure => l.adjTrueSeizure,
  AdjudicationVerdict.falseAlarm => l.adjFalseAlarm,
  AdjudicationVerdict.undetermined => l.adjUndetermined,
};

IconData verdictIcon(AdjudicationVerdict v) => switch (v) {
  AdjudicationVerdict.seizure => Icons.bolt_outlined,
  AdjudicationVerdict.falseAlarm => Icons.report_off_outlined,
  AdjudicationVerdict.undetermined => Icons.help_outline,
};

/// The tone a verdict is drawn in. `undetermined` is deliberately `unknown`
/// rather than a muted grey-on-grey: it is a real answer, not a missing one.
RiskView verdictView(AdjudicationVerdict v) => switch (v) {
  AdjudicationVerdict.seizure => RiskView.danger,
  AdjudicationVerdict.falseAlarm => RiskView.safe,
  AdjudicationVerdict.undetermined => RiskView.unknown,
};

/// §5.4 — the doctor's review queue.
///
/// What the plan requires and how this screen holds to it:
///
/// * **Three answers, not two.** «غير محدَّد» sits next to the other two as an
///   equal option. Forcing a binary would make doctors guess, and a guess
///   recorded as fact is worse for the accuracy figures than an honest gap.
/// * **This does not retrain anything.** Stated on screen, in `l.adjNoRetrainNote`,
///   not left as an assumption. `CareService.adjudicate` posts to
///   `/patients/{id}/outcomes` and nothing on that path touches the model.
/// * **Only what needs review.** Alerts that already carry a verdict are gone
///   from the queue — `LocalDatabase.adjudicatedAlertIds` exists for exactly
///   this — and informational alerts are never queued, because asking a doctor
///   to adjudicate «الحالة مستقرة» is how a review queue gets abandoned.
///
/// The queue is built from the local database rather than a server endpoint, so
/// it works on a hospital connection that comes and goes. Verdicts are written
/// locally and flushed through the outbox like every other care write.
class AdjudicationScreen extends StatefulWidget {
  const AdjudicationScreen({super.key});

  @override
  State<AdjudicationScreen> createState() => _AdjudicationScreenState();
}

class _AdjudicationScreenState extends State<AdjudicationScreen> {
  bool _loading = true;
  bool _busy = false;
  List<_Pending> _items = const [];
  Failure? _failure;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _load();
  }

  Future<void> _load() async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final out = <_Pending>[];
      for (final p in app.auth.accessiblePatients()) {
        final decided = await app.db.adjudicatedAlertIds(p.patientId);
        final alerts = await app.db.alertsFor(p.patientId, limit: 100);
        for (final a in alerts) {
          if (decided.contains(a.id)) continue;
          // `safe` means informational. Everything else — including a severity
          // string this build does not recognise — is worth a human look.
          if (alertSeverity(a.severity, l).view == RiskView.safe) continue;
          out.add(_Pending(alert: a, patientName: p.name));
        }
      }
      out.sort((x, y) => y.alert.timestamp.compareTo(x.alert.timestamp));
      if (!mounted) return;
      setState(() {
        _items = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = Failure.from(e);
        _loading = false;
      });
    }
  }

  Future<void> _decide(_Pending item) async {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final draft = await showModalBottomSheet<_Draft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _VerdictSheet(item: item),
    );
    if (draft == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await app.care.adjudicate(
        patientId: item.alert.patientId,
        alertId: item.alert.id,
        verdict: draft.verdict,
        notes: draft.notes,
        doctorId: app.auth.currentUser?.uid ?? '',
      );
      if (!mounted) return;
      // Dropped from the queue immediately rather than after a reload: the row
      // has a verdict now, and leaving it visible invites a second one.
      setState(() {
        _items = _items.where((i) => i.alert.id != item.alert.id).toList();
        _busy = false;
      });
      AppSnack.success(
        context,
        app.apiOnline ? l.adjSaved : l.savedLocallyWillSync,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnack.error(context, l.errUnknown);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(l.adjudicationTitle),
        actions: [
          IconButton(
            tooltip: l.retry,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AsyncView<List<_Pending>>(
        loading: _loading,
        failure: _failure,
        value: _items,
        isEmpty: (v) => v.isEmpty,
        onRetry: _load,
        emptyTitle: l.noAdjudicationsPending,
        emptyBody: l.adjNoRetrainNote,
        emptyIcon: Icons.done_all_outlined,
        builder: (context, items) => RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: Insets.pageBottomSafe,
            children: [
              OfflineBanner(
                visible: !app.apiOnline,
                pendingCount: app.care.pendingCount,
              ),
              InfoNote(text: l.adjudicationIntro, icon: Icons.rule_outlined),
              Gap.vSm,
              // The one sentence that decides whether a doctor trusts this
              // screen enough to use it. It is not a footnote.
              InfoNote(text: l.adjNoRetrainNote, icon: Icons.gavel_outlined),
              Gap.vMd,
              SectionCard(
                title: l.adjPending,
                icon: Icons.fact_check_outlined,
                trailing: Text(
                  '${items.length}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                child: Column(
                  children: [
                    for (final i in items)
                      _PendingTile(
                        item: i,
                        enabled: !_busy,
                        onDecide: () => _decide(i),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An alert still waiting for a verdict, with the name needed to show it. The
/// doctor's queue spans patients, so the name cannot be looked up once.
class _Pending {
  const _Pending({required this.alert, required this.patientName});

  final AlertItem alert;
  final String patientName;
}

class _Draft {
  const _Draft({required this.verdict, required this.notes});

  final AdjudicationVerdict verdict;
  final String notes;
}

class _PendingTile extends StatelessWidget {
  const _PendingTile({
    required this.item,
    required this.enabled,
    required this.onDecide,
  });

  final _Pending item;
  final bool enabled;
  final VoidCallback onDecide;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final s = alertSeverity(item.alert.severity, l);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.patientName.isEmpty
                          ? item.alert.patientId
                          : item.patientName,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      TimeAgo.stamp(item.alert.timestamp),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              RiskBadge(view: s.view, labelOverride: s.label, dense: true),
            ],
          ),
          if (item.alert.message.isNotEmpty) ...[
            Gap.vXs,
            Text(item.alert.message, style: theme.textTheme.bodySmall),
          ],
          Gap.vXs,
          SizedBox(
            height: A11y.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: enabled ? onDecide : null,
              icon: const Icon(Icons.gavel_outlined),
              label: Text(l.verdictLabel),
            ),
          ),
          const Divider(height: Gap.lg),
        ],
      ),
    );
  }
}

class _VerdictSheet extends StatefulWidget {
  const _VerdictSheet({required this.item});

  final _Pending item;

  @override
  State<_VerdictSheet> createState() => _VerdictSheetState();
}

class _VerdictSheetState extends State<_VerdictSheet> {
  final _notes = TextEditingController();
  AdjudicationVerdict? _verdict;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final alert = widget.item.alert;

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: Gap.lg + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.verdictLabel, style: theme.textTheme.titleMedium),
            Gap.vXs,
            Text(
              '${widget.item.patientName} · ${TimeAgo.stamp(alert.timestamp)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Gap.vMd,
            // Three full-width rows of equal height, in a fixed order. Equal
            // weight is the point: a smaller or greyer «غير محدَّد» would nudge
            // doctors into a decision they have not made.
            for (final v in AdjudicationVerdict.values) ...[
              _VerdictOption(
                verdict: v,
                selected: _verdict == v,
                onTap: () => setState(() => _verdict = v),
              ),
              Gap.vXs,
            ],
            Gap.vSm,
            TextField(
              controller: _notes,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: l.clinicalNotes,
                hintText: l.clinicalNotesHint,
                alignLabelWithHint: true,
              ),
            ),
            Gap.vLg,
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.cancel),
                  ),
                ),
                Gap.hSm,
                Expanded(
                  child: SizedBox(
                    height: A11y.minTouchTarget,
                    child: FilledButton(
                      // Disabled until a verdict is picked. There is no sensible
                      // default here — pre-selecting one would be putting words
                      // in the doctor's mouth.
                      onPressed: _verdict == null
                          ? null
                          : () => Navigator.pop(
                              context,
                              _Draft(
                                verdict: _verdict!,
                                notes: _notes.text,
                              ),
                            ),
                      child: Text(l.save),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VerdictOption extends StatelessWidget {
  const _VerdictOption({
    required this.verdict,
    required this.selected,
    required this.onTap,
  });

  final AdjudicationVerdict verdict;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tone = AppColors.of(context, verdictView(verdict));
    final label = verdictLabel(verdict, l);

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: Radii.rMd,
          child: Container(
            constraints: const BoxConstraints(
              minHeight: A11y.minTouchTarget,
            ),
            padding: Insets.tile,
            decoration: BoxDecoration(
              color: selected ? tone.container : null,
              border: Border.all(
                color: selected ? tone.solid : theme.dividerColor,
                width: selected ? 2 : 1,
              ),
              borderRadius: Radii.rMd,
            ),
            child: Row(
              children: [
                Icon(
                  verdictIcon(verdict),
                  color: selected ? tone.foreground : null,
                ),
                Gap.hSm,
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: selected
                          ? FontWeight.w800
                          : FontWeight.w500,
                      color: selected ? tone.foreground : null,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle_outline, color: tone.foreground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
