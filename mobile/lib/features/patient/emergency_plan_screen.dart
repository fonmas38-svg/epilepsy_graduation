import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../core/utils/external_actions.dart';
import '../../l10n/app_localizations.dart';
import '../../models/care_models.dart';
import '../../providers/app_state.dart';
import '../shared/first_aid_view.dart';

/// §3.5 — the emergency plan.
///
/// The hard requirement here is that **nothing on this screen may depend on the
/// network**. Contacts, the medical card and the first-aid steps all come from
/// SQLite, and the two actions it offers — dial and SMS — are handed to the OS.
/// The moment this screen matters is the moment the phone is most likely to have
/// no signal, so an online-only emergency plan is not an emergency plan.
class EmergencyPlanScreen extends StatelessWidget {
  const EmergencyPlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final care = app.care;
    final contacts = care.contacts;
    final card = care.medicalCard;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.emergencyTitle),
        actions: [
          IconButton(
            tooltip: l.medicalLockScreen,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MedicalLockScreen(),
              ),
            ),
            icon: const Icon(Icons.badge_outlined),
          ),
        ],
      ),
      // SOS pinned at the bottom, always visible (design §6).
      bottomNavigationBar: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 3,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
            child: Center(
              // heightFactor 1: in a bottom bar an unbounded Center fills the
              // whole screen and hides the page.
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: EmergencyButton(
                  label: l.needHelp,
                  busy: app.sosInProgress,
                  onPressed: app.sosInProgress ? null : () => app.triggerSos(),
                ),
              ),
            ),
          ),
        ),
      ),
      body: ResponsiveContent(
        maxWidth: 1000,
        child: ListView(
          padding: Insets.pageBottomSafe,
          children: [
            InfoNote(
              text: l.emergencyOfflineNote,
              icon: Icons.offline_bolt_outlined,
            ),
            Gap.vMd,
            // Responder card first: this screen is often handed to a
            // bystander or paramedic during a seizure.
            if (care.hasCardConflict) ...[
              _CardConflictBanner(
                onResolve: (keepLocal) =>
                    care.resolveCardConflict(keepLocal: keepLocal),
              ),
              Gap.vMd,
            ],
            _MedicalCardSection(card: card),
            Gap.vSm,
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, A11y.minTouchTarget),
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MedicalLockScreen(),
                  ),
                ),
                icon: const Icon(Icons.fullscreen_rounded),
                label: Text(
                  l.isArabic
                      ? 'عرض البطاقة للمسعف بملء الشاشة'
                      : 'Show card full screen for a responder',
                ),
              ),
            ),
            if (contacts.isNotEmpty) ...[
              Gap.vMd,
              // One large call to the highest-priority contact.
              SizedBox(
                height: 64,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.of(context, RiskView.safe).solid,
                    foregroundColor: AppColors.of(
                      context,
                      RiskView.safe,
                    ).onSolid,
                    textStyle: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: () async {
                    final ok = await ExternalActions.dial(contacts.first.phone);
                    if (!ok && context.mounted) {
                      AppSnack.warn(context, l.errUnknown);
                    }
                  },
                  icon: const Icon(Icons.call_rounded),
                  label: Text('${l.call} — ${contacts.first.name}'),
                ),
              ),
            ],
            Gap.vMd,
            SectionCard(
              title: l.contactsSection,
              subtitle: l.contactsHint,
              icon: Icons.contact_phone_outlined,
              trailing: IconButton(
                tooltip: l.addContact,
                onPressed: care.patientId == null
                    ? null
                    : () => _editContact(context, app, null),
                icon: const Icon(Icons.add_circle_outline),
              ),
              child: contacts.isEmpty
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        InfoNote(
                          text: l.noContactsWarning,
                          icon: Icons.warning_amber_rounded,
                          view: RiskView.caution,
                        ),
                        Gap.vSm,
                        EmptyState(
                          title: l.noContactsYet,
                          icon: Icons.contact_phone_outlined,
                          compact: true,
                          actionLabel: l.addContact,
                          action: care.patientId == null
                              ? null
                              : () => _editContact(context, app, null),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < contacts.length; i++)
                          _ContactTile(
                            contact: contacts[i],
                            rank: i + 1,
                            canMoveUp: i > 0,
                            canMoveDown: i < contacts.length - 1,
                            onMove: (delta) => _move(app, i, delta),
                            onEdit: () =>
                                _editContact(context, app, contacts[i]),
                            onDelete: () => _delete(context, app, contacts[i]),
                          ),
                        // The most important action on this screen gets a
                        // labelled, full-width button, not only the small «+».
                        Gap.vSm,
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, A11y.minTouchTarget),
                            ),
                            onPressed: care.patientId == null
                                ? null
                                : () => _editContact(context, app, null),
                            icon: const Icon(Icons.person_add_alt_1_outlined),
                            label: Text(l.addContact),
                          ),
                        ),
                      ],
                    ),
            ),
            Gap.vMd,
            const FirstAidView(),
          ],
        ),
      ),
    );
  }

  Future<void> _move(AppState app, int index, int delta) async {
    final ordered = [...app.care.contacts];
    final target = index + delta;
    if (target < 0 || target >= ordered.length) return;
    final moved = ordered.removeAt(index);
    ordered.insert(target, moved);
    await app.care.reorderContacts(ordered);
  }

  Future<void> _delete(
    BuildContext context,
    AppState app,
    EmergencyContact contact,
  ) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.confirmDelete),
        content: Text('${contact.name} — ${contact.phone}'),
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
      await app.care.deleteContact(contact);
      if (context.mounted) AppSnack.success(context, l.deleted);
    } catch (_) {
      if (context.mounted) AppSnack.error(context, l.errUnknown);
    }
  }

  Future<void> _editContact(
    BuildContext context,
    AppState app,
    EmergencyContact? existing,
  ) async {
    final l = AppLocalizations.of(context);
    final draft = await showModalBottomSheet<_ContactDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ContactSheet(existing: existing),
    );
    if (draft == null || !context.mounted) return;
    try {
      await app.care.saveContact(
        id: existing?.id,
        name: draft.name,
        phone: draft.phone,
        relation: draft.relation,
        priority: existing?.priority,
      );
      if (!context.mounted) return;
      AppSnack.success(
        context,
        app.apiOnline ? l.contactSaved : l.savedLocallyWillSync,
      );
    } catch (_) {
      if (context.mounted) AppSnack.error(context, l.errUnknown);
    }
  }
}

// --- contacts ---------------------------------------------------------------

class _ContactTile extends StatelessWidget {
  const _ContactTile({
    required this.contact,
    required this.rank,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMove,
    required this.onEdit,
    required this.onDelete,
  });

  final EmergencyContact contact;
  final int rank;
  final bool canMoveUp;
  final bool canMoveDown;
  final void Function(int delta) onMove;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  Future<void> _call(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final ok = await ExternalActions.dial(contact.phone);
    if (!context.mounted || ok) return;
    AppSnack.error(context, l.callFailed);
  }

  Future<void> _sms(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final ok = await ExternalActions.sms(contact.phone);
    if (!context.mounted || ok) return;
    AppSnack.error(context, l.callFailed);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = AppColors.of(context, RiskView.danger);
    final subtitle = [
      contact.phone,
      if (contact.relation.isNotEmpty) contact.relation,
      if (!contact.synced) l.pendingSync,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.container,
                  borderRadius: Radii.rPill,
                  border: Border.all(color: colors.border),
                ),
                child: Text(
                  '$rank',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Gap.hSm,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.name,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: l.edit,
                icon: const Icon(Icons.more_vert),
                onSelected: (value) => switch (value) {
                  'edit' => onEdit(),
                  'up' => onMove(-1),
                  'down' => onMove(1),
                  _ => onDelete(),
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'edit', child: Text(l.edit)),
                  if (canMoveUp)
                    PopupMenuItem(value: 'up', child: Text(l.moveUp)),
                  if (canMoveDown)
                    PopupMenuItem(value: 'down', child: Text(l.moveDown)),
                  PopupMenuItem(value: 'delete', child: Text(l.delete)),
                ],
              ),
            ],
          ),
          Gap.vXs,
          // Side by side normally; stacked full width under large text so
          // neither label is clipped (design system: 200 % text check).
          Builder(
            builder: (context) {
              final call = ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: A11y.minTouchTarget,
                ),
                child: FilledButton.icon(
                  onPressed: () => _call(context),
                  icon: const Icon(Icons.call_outlined),
                  label: Text(l.callNow),
                ),
              );
              final sms = ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: A11y.minTouchTarget,
                ),
                child: OutlinedButton.icon(
                  onPressed: () => _sms(context),
                  icon: const Icon(Icons.sms_outlined),
                  label: Text(l.message),
                ),
              );
              final largeText = MediaQuery.textScalerOf(context).scale(14) > 21;
              if (largeText) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [call, Gap.vSm, sms],
                );
              }
              return Row(
                children: [
                  Expanded(child: call),
                  Gap.hSm,
                  Expanded(child: sms),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ContactDraft {
  const _ContactDraft({
    required this.name,
    required this.phone,
    required this.relation,
  });
  final String name;
  final String phone;
  final String relation;
}

class _ContactSheet extends StatefulWidget {
  const _ContactSheet({this.existing});

  final EmergencyContact? existing;

  @override
  State<_ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends State<_ContactSheet> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _relation;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _phone = TextEditingController(text: widget.existing?.phone ?? '');
    _relation = TextEditingController(text: widget.existing?.relation ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _relation.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState?.validate() != true) return;
    Navigator.pop(
      context,
      _ContactDraft(
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        relation: _relation.text.trim(),
      ),
    );
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
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.existing == null ? l.addContact : l.edit,
                  style: theme.textTheme.titleLarge,
                ),
                Gap.vMd,
                TextFormField(
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l.contactName,
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? l.requiredField : null,
                ),
                Gap.vSm,
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  // Digits plus the handful of separators a real number carries;
                  // `ExternalActions.normalisePhone` strips the rest before dialling.
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-() ]')),
                  ],
                  decoration: InputDecoration(
                    labelText: l.contactPhone,
                    prefixIcon: const Icon(Icons.phone_outlined),
                  ),
                  validator: (v) {
                    final digits = ExternalActions.normalisePhone(v ?? '');
                    if (digits.replaceAll('+', '').length < 6) {
                      return l.requiredField;
                    }
                    return null;
                  },
                ),
                Gap.vSm,
                TextFormField(
                  controller: _relation,
                  decoration: InputDecoration(
                    labelText: '${l.contactRelation} (${l.optional})',
                    prefixIcon: const Icon(Icons.family_restroom_outlined),
                  ),
                ),
                Gap.vLg,
                SizedBox(
                  height: A11y.minTouchTarget,
                  child: FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(l.save),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- medical card -----------------------------------------------------------

class _MedicalCardSection extends StatelessWidget {
  const _MedicalCardSection({required this.card});

  final MedicalCard? card;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final c = card;

    return SectionCard(
      title: l.medicalCard,
      icon: Icons.medical_information_outlined,
      trailing: IconButton(
        tooltip: l.edit,
        onPressed: app.care.patientId == null
            ? null
            : () => _edit(context, app, c),
        icon: const Icon(Icons.edit_outlined),
      ),
      child: c == null || c.isEmpty
          ? EmptyState(
              title: l.medicalCardEmpty,
              icon: Icons.medical_information_outlined,
              compact: true,
              actionLabel: l.edit,
              action: app.care.patientId == null
                  ? null
                  : () => _edit(context, app, c),
            )
          : Column(
              children: [
                if (c.diagnosis.isNotEmpty)
                  LabeledValue(
                    label: l.diagnosis,
                    value: c.diagnosis,
                    icon: Icons.healing_outlined,
                  ),
                if (c.allergies.isNotEmpty) ...[
                  Gap.vSm,
                  LabeledValue(
                    label: l.allergies,
                    value: c.allergies,
                    icon: Icons.dangerous_outlined,
                  ),
                ],
                if (c.bloodType.isNotEmpty) ...[
                  Gap.vSm,
                  LabeledValue(
                    label: l.bloodType,
                    value: c.bloodType,
                    icon: Icons.bloodtype_outlined,
                  ),
                ],
                if (c.doctorName.isNotEmpty) ...[
                  Gap.vSm,
                  LabeledValue(
                    label: l.treatingDoctor,
                    value: c.doctorName,
                    icon: Icons.medical_services_outlined,
                  ),
                ],
                if (c.doctorPhone.isNotEmpty) ...[
                  Gap.vSm,
                  LabeledValue(
                    label: l.doctorPhone,
                    value: c.doctorPhone,
                    icon: Icons.phone_outlined,
                  ),
                ],
                if (c.usualAddress.isNotEmpty) ...[
                  Gap.vSm,
                  LabeledValue(
                    label: Localizations.localeOf(context).languageCode == 'ar'
                        ? 'العنوان المعتاد'
                        : 'Usual address',
                    value: c.usualAddress,
                    icon: Icons.home_outlined,
                  ),
                ],
                if (c.notes.isNotEmpty) ...[
                  Gap.vSm,
                  LabeledValue(
                    label: l.notesLabel,
                    value: c.notes,
                    icon: Icons.note_alt_outlined,
                  ),
                ],
              ],
            ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    AppState app,
    MedicalCard? existing,
  ) async {
    final l = AppLocalizations.of(context);
    final pid = app.care.patientId;
    if (pid == null) return;
    final draft = await showModalBottomSheet<MedicalCard>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _MedicalCardSheet(card: existing ?? MedicalCard(patientId: pid)),
    );
    if (draft == null || !context.mounted) return;
    try {
      await app.care.saveMedicalCard(draft);
      if (!context.mounted) return;
      AppSnack.success(
        context,
        app.apiOnline ? l.medicalCardSaved : l.savedLocallyWillSync,
      );
    } catch (_) {
      if (context.mounted) AppSnack.error(context, l.errUnknown);
    }
  }
}

class _MedicalCardSheet extends StatefulWidget {
  const _MedicalCardSheet({required this.card});

  final MedicalCard card;

  @override
  State<_MedicalCardSheet> createState() => _MedicalCardSheetState();
}

class _MedicalCardSheetState extends State<_MedicalCardSheet> {
  late final TextEditingController _diagnosis;
  late final TextEditingController _allergies;
  late final TextEditingController _bloodType;
  late final TextEditingController _doctorName;
  late final TextEditingController _doctorPhone;
  late final TextEditingController _notes;
  late final TextEditingController _address;

  @override
  void initState() {
    super.initState();
    final c = widget.card;
    _diagnosis = TextEditingController(text: c.diagnosis);
    _allergies = TextEditingController(text: c.allergies);
    _bloodType = TextEditingController(text: c.bloodType);
    _doctorName = TextEditingController(text: c.doctorName);
    _doctorPhone = TextEditingController(text: c.doctorPhone);
    _notes = TextEditingController(text: c.notes);
    _address = TextEditingController(text: c.usualAddress);
  }

  @override
  void dispose() {
    _diagnosis.dispose();
    _allergies.dispose();
    _bloodType.dispose();
    _doctorName.dispose();
    _doctorPhone.dispose();
    _notes.dispose();
    _address.dispose();
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
              Text(l.medicalCard, style: theme.textTheme.titleLarge),
              Gap.vMd,
              _field(_diagnosis, l.diagnosis, Icons.healing_outlined),
              Gap.vSm,
              _field(_allergies, l.allergies, Icons.dangerous_outlined),
              Gap.vSm,
              _field(_bloodType, l.bloodType, Icons.bloodtype_outlined),
              Gap.vSm,
              _field(
                _doctorName,
                l.treatingDoctor,
                Icons.medical_services_outlined,
              ),
              Gap.vSm,
              _field(
                _doctorPhone,
                l.doctorPhone,
                Icons.phone_outlined,
                keyboard: TextInputType.phone,
              ),
              Gap.vSm,
              _field(
                _address,
                Localizations.localeOf(context).languageCode == 'ar'
                    ? 'العنوان المعتاد (يُرسل إن تعذّر تحديد الموقع)'
                    : 'Usual address (sent if location is unavailable)',
                Icons.home_outlined,
                lines: 2,
              ),
              Gap.vSm,
              _field(_notes, l.notesLabel, Icons.note_alt_outlined, lines: 3),
              Gap.vLg,
              SizedBox(
                height: A11y.minTouchTarget,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    widget.card.copyWith(
                      diagnosis: _diagnosis.text.trim(),
                      allergies: _allergies.text.trim(),
                      bloodType: _bloodType.text.trim(),
                      doctorName: _doctorName.text.trim(),
                      doctorPhone: _doctorPhone.text.trim(),
                      notes: _notes.text.trim(),
                      usualAddress: _address.text.trim(),
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

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? keyboard,
    int lines = 1,
  }) => TextField(
    controller: controller,
    keyboardType: keyboard,
    maxLines: lines,
    decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
  );
}

// --- lock screen ------------------------------------------------------------

/// The «شاشة طبية للطوارئ» of §3.5: everything a stranger holding the phone needs,
/// in large type, with no navigation and no dependence on the network.
///
/// Deliberately not interactive beyond calling the first contact — someone using
/// this is under stress and must not have to find anything.
class MedicalLockScreen extends StatelessWidget {
  const MedicalLockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final card = app.care.medicalCard;
    final contacts = app.care.contacts;
    final pid = app.activePatientId;
    final profile = pid == null ? null : app.auth.patientById(pid);
    final colors = AppColors.of(context, RiskView.danger);

    return Scaffold(
      backgroundColor: colors.container,
      appBar: AppBar(
        title: Text(l.medicalLockScreen),
        backgroundColor: colors.container,
      ),
      body: ListView(
        padding: Insets.pageBottomSafe,
        children: [
          Text(
            l.lockScreenHint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.foreground,
            ),
          ),
          Gap.vMd,
          Row(
            children: [
              Icon(
                Icons.health_and_safety_outlined,
                size: 32,
                color: colors.foreground,
              ),
              Gap.hSm,
              Expanded(
                child: Text(
                  profile?.name ?? l.unknown,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.foreground,
                  ),
                ),
              ),
            ],
          ),
          Gap.vSm,
          Text(
            card?.diagnosis.isNotEmpty == true
                ? card!.diagnosis
                : (profile?.diagnosis ?? l.unknown),
            style: theme.textTheme.titleLarge?.copyWith(
              color: colors.foreground,
            ),
          ),
          Gap.vMd,
          if (card != null && !card.isEmpty)
            SectionCard(
              title: l.medicalCard,
              icon: Icons.medical_information_outlined,
              child: Column(
                children: [
                  if (card.allergies.isNotEmpty)
                    LabeledValue(
                      label: l.allergies,
                      value: card.allergies,
                      icon: Icons.dangerous_outlined,
                      valueColor: colors.foreground,
                    ),
                  if (card.bloodType.isNotEmpty) ...[
                    Gap.vSm,
                    LabeledValue(
                      label: l.bloodType,
                      value: card.bloodType,
                      icon: Icons.bloodtype_outlined,
                    ),
                  ],
                  if (card.doctorName.isNotEmpty) ...[
                    Gap.vSm,
                    LabeledValue(
                      label: l.treatingDoctor,
                      value: card.doctorName,
                      icon: Icons.medical_services_outlined,
                    ),
                  ],
                  if (card.notes.isNotEmpty) ...[
                    Gap.vSm,
                    LabeledValue(
                      label: l.notesLabel,
                      value: card.notes,
                      icon: Icons.note_alt_outlined,
                    ),
                  ],
                ],
              ),
            ),
          if (contacts.isNotEmpty) ...[
            Gap.vMd,
            SizedBox(
              height: A11y.emergencyTouchTarget,
              child: FilledButton.icon(
                onPressed: () async {
                  final ok = await ExternalActions.dial(contacts.first.phone);
                  if (!context.mounted || ok) return;
                  AppSnack.error(context, l.callFailed);
                },
                icon: const Icon(Icons.call_outlined),
                label: Text('${l.callNow} — ${contacts.first.name}'),
              ),
            ),
          ],
          Gap.vMd,
          const FirstAidView(),
        ],
      ),
    );
  }
}

class _CardConflictBanner extends StatelessWidget {
  const _CardConflictBanner({required this.onResolve});

  final Future<void> Function(bool keepLocal) onResolve;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);

    return Card(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.7),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.error),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: theme.colorScheme.error,
                ),
                Gap.hSm,
                Expanded(
                  child: Text(
                    l.cardConflictWarning,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            Gap.vSm,
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () => onResolve(false),
                  child: Text(l.acceptServerVersion),
                ),
                Gap.hSm,
                FilledButton.tonal(
                  onPressed: () => onResolve(true),
                  child: Text(l.keepLocalVersion),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
