import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failure.dart';
import '../../core/enums.dart';
import '../../core/router/route_names.dart';
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
import 'event_evidence_view.dart';

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
  const AdjudicationScreen({super.key, this.args});
  final PatientRouteArgs? args;

  @override
  State<AdjudicationScreen> createState() => _AdjudicationScreenState();
}

class _AdjudicationScreenState extends State<AdjudicationScreen> {
  late final AppState _app;
  late final AppUser? _owner;
  late final String _origin;
  late final int _revision;
  bool get _current =>
      mounted &&
      AppUser.sameSessionOwner(_owner, _app.auth.currentUser) &&
      _owner?.role == UserRole.doctor &&
      _origin == _app.api.baseUrl &&
      _revision == _app.api.tokens.revision;
  bool _loading = true;
  bool _busy = false;
  List<_Pending> _items = const [];
  Failure? _failure;
  int? _cursor;
  int _offset = 0;
  bool _remote = false;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _owner = _app.auth.currentUser;
    _origin = _app.api.baseUrl;
    _revision = _app.api.tokens.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load({bool more = false}) async {
    if (!_current) return;
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final patients = app.auth
          .accessiblePatients()
          .where(
            (p) => widget.args == null || widget.args!.patientId == p.patientId,
          )
          .toList();
      final names = {for (final p in patients) p.patientId: p.name};
      final page = <_Pending>[];
      var remote = more && _remote;
      if (!more) {
        _cursor = null;
        _offset = 0;
      }
      if ((more && _remote) ||
          (!more && !app.auth.isDemoSession && app.api.tokens.hasSession)) {
        try {
          final response = await app.api.sendJson(
            method: 'GET',
            path: Uri(
              path: '/doctor/review-queue',
              queryParameters: {
                'limit': '50',
                if (more && _cursor != null) 'before': '$_cursor',
                if (widget.args != null) 'patient_id': widget.args!.patientId,
              },
            ).toString(),
          );
          if (!_current) return;
          if (response['items'] is! List) {
            throw const FormatException('Invalid review queue');
          }
          for (final raw in response['items'] as List) {
            final item = Map<String, dynamic>.from(raw as Map);
            final alert = AlertItem.fromMap(
              Map<String, dynamic>.from(item['alert'] as Map),
            ).copyWith(serverOrigin: app.dataOrigin);
            if (!names.containsKey(alert.patientId)) {
              throw const FormatException('Unauthorized queue patient');
            }
            await app.db.insertAlert(alert);
            if (!_current) return;
            final local = await app.db.adjudicatedAlertIds(
              alert.patientId,
              serverOrigin: app.dataOrigin,
            );
            if (!local.contains(alert.id)) {
              page.add(
                _Pending(alert: alert, patientName: names[alert.patientId]!),
              );
            }
          }
          _cursor = (response['nextCursor'] as num?)?.toInt();
          _hasMore = _cursor != null;
          remote = true;
        } catch (error) {
          final failure = Failure.from(error);
          if (more ||
              (!failure.isConnectivity &&
                  failure.kind != FailureKind.notFound)) {
            rethrow;
          }
          remote = false;
        }
      }
      if (!remote) {
        final rows = await app.db.pendingReviewAlerts(
          names.keys.toList(),
          serverOrigin: app.dataOrigin,
          offset: _offset,
          limit: 51,
        );
        if (!_current) return;
        _hasMore = rows.length > 50;
        final slice = rows.take(50).toList();
        _offset += slice.length;
        page.addAll(
          slice.map(
            (alert) =>
                _Pending(alert: alert, patientName: names[alert.patientId]!),
          ),
        );
      }
      if (!_current) return;
      setState(() {
        _remote = remote;
        _items = [...(more ? _items : <_Pending>[]), ...page];
        _loading = false;
      });
    } catch (error) {
      if (!_current) return;
      setState(() {
        _loading = false;
        if (!more) _failure = Failure.from(error);
      });
      if (more && mounted) {
        AppSnack.error(context, AppLocalizations.of(context).errUnknown);
      }
    }
  }

  Future<void> _decide(_Pending item) async {
    if (!_current ||
        _busy ||
        !_app.auth.canAccessPatient(item.alert.patientId)) {
      return;
    }
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final draft = await showModalBottomSheet<_Draft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _VerdictSheet(item: item),
    );
    if (draft == null || !_current) return;
    setState(() => _busy = true);
    try {
      final combinedNotes = [
        if (draft.semiology != null && draft.semiology!.isNotEmpty)
          'التصنيف السريري: ${draft.semiology}',
        if (draft.artifactCause != null && draft.artifactCause!.isNotEmpty)
          'سبب التنبيه الكاذب: ${draft.artifactCause}',
        if (draft.notes.trim().isNotEmpty) draft.notes.trim(),
      ].join(' | ');
      await app.care.adjudicate(
        patientId: item.alert.patientId,
        alertId: item.alert.id,
        verdict: draft.verdict,
        notes: combinedNotes,
        doctorId: _owner?.uid ?? '',
        seizureType: draft.semiology,
        artifactCause: draft.artifactCause,
      );
      if (!_current || !mounted) return;
      // Dropped from the queue immediately rather than after a reload: the row
      // has a verdict now, and leaving it visible invites a second one.
      setState(() {
        _items = _items.where((i) => i.alert.id != item.alert.id).toList();
        if (!_remote && _offset > 0) _offset--;
        _busy = false;
      });
      AppSnack.success(context, l.savedLocallyWillSync);
    } catch (_) {
      if (!_current || !mounted) return;
      setState(() => _busy = false);
      AppSnack.error(context, l.errUnknown);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    if (!_current) return const Scaffold(body: SizedBox.shrink());

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
        isEmpty: (v) => v.isEmpty && !_hasMore,
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
                visible: !_remote,
                pendingCount: app.care.pendingCount,
              ),
              InfoNote(
                text: _remote
                    ? (l.isArabic
                          ? 'طابور الخادم؛ التحديث يجلب قرارات الأطباء الآخرين.'
                          : 'Server queue; refresh reconciles other clinicians’ reviews.')
                    : (l.isArabic
                          ? 'نسخة محلية؛ قد توجد تنبيهات وقرارات أحدث على الخادم.'
                          : 'Local copy; newer alerts and decisions may exist on the server.'),
                icon: Icons.sync,
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
                    if (_hasMore)
                      OutlinedButton.icon(
                        onPressed: _loading ? null : () => _load(more: true),
                        icon: const Icon(Icons.expand_more),
                        label: Text(l.isArabic ? 'تحميل المزيد' : 'Load more'),
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
  const _Draft({
    required this.verdict,
    required this.notes,
    this.semiology,
    this.artifactCause,
  });

  final AdjudicationVerdict verdict;
  final String notes;
  final String? semiology;
  final String? artifactCause;
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
  String _semiology = 'نوبة بؤرية (Focal)';
  String _artifactCause = 'حركة الرأس أو المضغ (Motion/EMG)';

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
    final ar = l.isArabic;

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
              '${widget.item.patientName} · ${TimeAgo.stamp(alert.timestamp, l)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Gap.vSm,
            EventEvidenceView(patientId: alert.patientId, alertId: alert.id),
            Gap.vMd,
            for (final v in AdjudicationVerdict.values) ...[
              _VerdictOption(
                verdict: v,
                selected: _verdict == v,
                onTap: () => setState(() => _verdict = v),
              ),
              Gap.vXs,
            ],
            if (_verdict == AdjudicationVerdict.seizure) ...[
              Gap.vSm,
              DropdownButtonFormField<String>(
                initialValue: _semiology,
                decoration: InputDecoration(
                  labelText: ar
                      ? 'نوع النوبة (Semiology)'
                      : 'Seizure semiology',
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'نوبة بؤرية (Focal)',
                    child: Text('نوبة بؤرية (Focal)'),
                  ),
                  DropdownMenuItem(
                    value: 'نوبة معممة (Generalized)',
                    child: Text('نوبة معممة (Generalized)'),
                  ),
                  DropdownMenuItem(
                    value: 'نوبة غيابية (Absence)',
                    child: Text('نوبة غيابية (Absence)'),
                  ),
                  DropdownMenuItem(
                    value: 'أخرى (Other)',
                    child: Text('أخرى (Other)'),
                  ),
                ],
                onChanged: (v) => setState(() => _semiology = v ?? _semiology),
              ),
            ],
            if (_verdict == AdjudicationVerdict.falseAlarm) ...[
              Gap.vSm,
              DropdownButtonFormField<String>(
                initialValue: _artifactCause,
                decoration: InputDecoration(
                  labelText: ar
                      ? 'سبب التشويش / الإنذار الكاذب'
                      : 'Artifact cause',
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'حركة الرأس أو المضغ (Motion/EMG)',
                    child: Text('حركة الرأس أو المضغ (Motion/EMG)'),
                  ),
                  DropdownMenuItem(
                    value: 'ارتخاء القطب (Electrode pop)',
                    child: Text('ارتخاء القطب (Electrode pop)'),
                  ),
                  DropdownMenuItem(
                    value: 'نشاط بدني طبيعي (Exercise)',
                    child: Text('نشاط بدني طبيعي (Exercise)'),
                  ),
                ],
                onChanged: (v) =>
                    setState(() => _artifactCause = v ?? _artifactCause),
              ),
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
                      onPressed: _verdict == null
                          ? null
                          : () => Navigator.pop(
                              context,
                              _Draft(
                                verdict: _verdict!,
                                notes: _notes.text,
                                semiology:
                                    _verdict == AdjudicationVerdict.seizure
                                    ? _semiology
                                    : null,
                                artifactCause:
                                    _verdict == AdjudicationVerdict.falseAlarm
                                    ? _artifactCause
                                    : null,
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
            constraints: const BoxConstraints(minHeight: A11y.minTouchTarget),
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
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
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
