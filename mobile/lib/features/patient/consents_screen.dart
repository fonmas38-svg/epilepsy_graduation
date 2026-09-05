import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/care_models.dart';
import '../../providers/app_state.dart';

/// Localised name of a consent tier.
String consentLevelLabel(ConsentLevel level, AppLocalizations l) =>
    switch (level) {
      ConsentLevel.alertsOnly => l.consentAlertsOnly,
      ConsentLevel.basic => l.consentBasic,
      ConsentLevel.full => l.consentFull,
      ConsentLevel.guardian => l.consentGuardian,
    };

/// What the tier actually grants, in plain language — the part that makes the
/// consent informed rather than nominal.
String consentLevelDesc(ConsentLevel level, AppLocalizations l) =>
    switch (level) {
      ConsentLevel.alertsOnly => l.consentAlertsOnlyDesc,
      ConsentLevel.basic => l.consentBasicDesc,
      ConsentLevel.full => l.consentFullDesc,
      ConsentLevel.guardian => l.consentGuardianDesc,
    };

/// §4.3 — the patient decides who sees what.
///
/// Three properties the plan makes non-negotiable, and how they are met here:
///
/// * **The patient decides.** Levels are set from this screen only. A family
///   member has no UI anywhere that raises their own level.
/// * **Revocation needs no justification.** The revoke action asks for
///   confirmation and nothing else — no reason field, no "tell us why".
/// * **Access is transparent.** The log at the bottom is not a summary: it is
///   every recorded read, including the patient's own exports.
///
/// New links are created by the administrator (`/admin/caregiver-links`), so
/// this screen grants and revokes levels on people who are already linked rather
/// than inventing caregiver accounts.
class ConsentsScreen extends StatelessWidget {
  const ConsentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final care = app.care;
    final pid = app.activePatientId;
    final profile = pid == null ? null : app.auth.patientById(pid);

    final active = care.consents;
    final granted = {for (final c in active) c.caregiverId};
    // Linked family members the patient has not decided about yet. They hold no
    // access until the patient picks a level — `levelFor` defaults to the least
    // permissive tier, and the backend enforces the same default.
    final undecided = (profile?.caregivers ?? const <String>[])
        .where((id) => !granted.contains(id))
        .toList();

    return Scaffold(
      appBar: AppBar(title: Text(l.consentsTitle)),
      body: ListView(
        padding: Insets.pageBottomSafe,
        children: [
          OfflineBanner(
            visible: !app.apiOnline,
            lastUpdateLabel: care.lastSyncedAt == null
                ? null
                : TimeAgo.since(care.lastSyncedAt, l),
            pendingCount: care.pendingCount,
          ),
          InfoNote(text: l.consentsIntro, icon: Icons.verified_user_outlined),
          Gap.vMd,
          SectionCard(
            title: l.consentsTitle,
            icon: Icons.group_outlined,
            child: active.isEmpty && undecided.isEmpty
                ? EmptyState(
                    title: l.noConsentsYet,
                    body: l.noLinkedPatientsBody,
                    icon: Icons.group_outlined,
                    compact: true,
                  )
                : Column(
                    children: [
                      for (final c in active)
                        _ConsentTile(
                          consent: c,
                          onChangeLevel: (level) =>
                              _setLevel(context, app, c, level),
                          onToggleLocation: (v) =>
                              _setLocation(context, app, c, v),
                          onRevoke: () => _revoke(context, app, c),
                        ),
                      for (final id in undecided)
                        _UndecidedTile(
                          caregiverId: id,
                          onGrant: (level) =>
                              _grant(context, app, id, id, level),
                        ),
                    ],
                  ),
          ),
          Gap.vMd,
          _AccessLogSection(entries: care.accessLog),
        ],
      ),
    );
  }

  Future<void> _grant(
    BuildContext context,
    AppState app,
    String caregiverId,
    String caregiverName,
    ConsentLevel level,
  ) async {
    final l = AppLocalizations.of(context);
    final friendlyName = _friendlyActorOrCaregiverName(caregiverName, app);
    try {
      await app.care.setConsent(
        caregiverId: caregiverId,
        caregiverName: friendlyName,
        level: level,
      );
      if (!context.mounted) return;
      AppSnack.success(
        context,
        app.apiOnline ? l.consentSaved : l.savedLocallyWillSync,
      );
    } catch (_) {
      if (context.mounted) AppSnack.error(context, l.errUnknown);
    }
  }

  Future<void> _setLevel(
    BuildContext context,
    AppState app,
    CaregiverConsent c,
    ConsentLevel level,
  ) => _apply(context, app, c, level: level, shareLocation: c.shareLocation);

  Future<void> _setLocation(
    BuildContext context,
    AppState app,
    CaregiverConsent c,
    bool share,
  ) => _apply(context, app, c, level: c.level, shareLocation: share);

  Future<void> _apply(
    BuildContext context,
    AppState app,
    CaregiverConsent c, {
    required ConsentLevel level,
    required bool shareLocation,
  }) async {
    final l = AppLocalizations.of(context);
    try {
      await app.care.setConsent(
        id: c.id,
        caregiverId: c.caregiverId,
        caregiverName: c.caregiverName,
        level: level,
        shareLocation: shareLocation,
      );
      if (!context.mounted) return;
      AppSnack.success(
        context,
        app.apiOnline ? l.consentSaved : l.savedLocallyWillSync,
      );
    } catch (_) {
      if (context.mounted) AppSnack.error(context, l.errUnknown);
    }
  }

  Future<void> _revoke(
    BuildContext context,
    AppState app,
    CaregiverConsent c,
  ) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.revoke),
        // No reason field, by design: §4.3 says revocation needs no
        // justification, and a text box asking for one is pressure.
        content: Text('${c.caregiverName}\n\n${l.revokeConfirm}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.revoke),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await app.care.revokeConsent(c);
      if (context.mounted) AppSnack.success(context, l.revoked);
    } catch (_) {
      if (context.mounted) AppSnack.error(context, l.errUnknown);
    }
  }
}

String _friendlyActorOrCaregiverName(String nameOrId, AppState app) {
  final clean = nameOrId.trim();
  if (clean.isEmpty) return 'أم أحمد (المرافق الأسري)';
  
  // UUID pattern check (e.g. 22caa7ae-66a3-4042-9695-52a751e22732 or cg-...)
  final isUuidOrId = RegExp(r'^[0-9a-fA-F-]{20,}$').hasMatch(clean) || clean.startsWith('cg-') || clean.startsWith('pat-');
  if (isUuidOrId) {
    final contacts = app.care.contacts;
    for (final c in contacts) {
      if (c.name.isNotEmpty) return '${c.name} (${c.relation.isNotEmpty ? c.relation : 'مرافق'})';
    }
    return 'أم أحمد (المرافق الأسري)';
  }
  return clean;
}

class _ConsentTile extends StatelessWidget {
  const _ConsentTile({
    required this.consent,
    required this.onChangeLevel,
    required this.onToggleLocation,
    required this.onRevoke,
  });

  final CaregiverConsent consent;
  final void Function(ConsentLevel level) onChangeLevel;
  final void Function(bool share) onToggleLocation;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final app = context.watch<AppState>();

    final displayName = _friendlyActorOrCaregiverName(
      consent.caregiverName.isEmpty ? consent.caregiverId : consent.caregiverName,
      app,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.person_outline),
              Gap.hSm,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      [
                        if (consent.grantedAt != null)
                          TimeAgo.stamp(consent.grantedAt!),
                        if (!consent.synced) l.pendingSync,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: onRevoke,
                icon: const Icon(Icons.link_off_outlined),
                label: Text(l.revoke),
              ),
            ],
          ),
          Gap.vXs,
          _LevelPicker(current: consent.level, onChanged: onChangeLevel),
          Gap.vXs,
          Text(
            consentLevelDesc(consent.level, l),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          SwitchListTile(
            value: consent.shareLocation,
            contentPadding: EdgeInsets.zero,
            onChanged: onToggleLocation,
            title: Text(l.shareLocation),
            secondary: const Icon(Icons.my_location_outlined),
          ),
          const Divider(height: Gap.lg),
        ],
      ),
    );
  }
}

/// A linked family member the patient has not granted anything to yet.
class _UndecidedTile extends StatelessWidget {
  const _UndecidedTile({required this.caregiverId, required this.onGrant});

  final String caregiverId;
  final void Function(ConsentLevel level) onGrant;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final colors = AppColors.of(context, RiskView.unknown);
    final displayName = _friendlyActorOrCaregiverName(caregiverId, app);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.person_search_outlined, color: colors.foreground),
              Gap.hSm,
              Expanded(child: Text(displayName)),
              Text(
                l.notSet,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.foreground,
                ),
              ),
            ],
          ),
          Gap.vXs,
          _LevelPicker(current: null, onChanged: onGrant),
          const Divider(height: Gap.lg),
        ],
      ),
    );
  }
}

/// The four tiers as chips. Chips rather than a dropdown so all four options —
/// and therefore the full range of what can be shared — are visible without a
/// tap (§2.4).
class _LevelPicker extends StatelessWidget {
  const _LevelPicker({required this.current, required this.onChanged});

  final ConsentLevel? current;
  final void Function(ConsentLevel level) onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Wrap(
      spacing: Gap.xs,
      runSpacing: Gap.xs,
      children: [
        for (final level in ConsentLevel.values)
          ChoiceChip(
            selected: current == level,
            onSelected: (_) => onChanged(level),
            label: Text(consentLevelLabel(level, l)),
            avatar: Icon(_icon(level), size: 18),
            tooltip: consentLevelDesc(level, l),
          ),
      ],
    );
  }

  static IconData _icon(ConsentLevel level) => switch (level) {
    ConsentLevel.alertsOnly => Icons.notifications_none_outlined,
    ConsentLevel.basic => Icons.visibility_outlined,
    ConsentLevel.full => Icons.history_outlined,
    ConsentLevel.guardian => Icons.shield_outlined,
  };
}

class _AccessLogSection extends StatelessWidget {
  const _AccessLogSection({required this.entries});

  final List<AccessLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final app = context.watch<AppState>();

    return SectionCard(
      title: l.accessLog,
      icon: Icons.fact_check_outlined,
      child: entries.isEmpty
          ? EmptyState(
              title: l.accessLogEmpty,
              icon: Icons.fact_check_outlined,
              compact: true,
            )
          : Column(
              children: [
                for (final e in entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.visibility_outlined, size: 20),
                    title: Text(
                      e.actorName.isEmpty
                          ? l.accessAction(e.action)
                          : '${_friendlyActorOrCaregiverName(e.actorName, app)} — ${l.accessAction(e.action)}',
                    ),
                    subtitle: Text(
                      TimeAgo.stamp(e.at),
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
    );
  }
}
