import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/enums.dart';
import '../../core/errors/failure.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../core/utils/time_ago.dart';
import '../../core/utils/doctor_title_formatter.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../widgets/patient_location_card.dart';

class ClinicalMessagesScreen extends StatefulWidget {
  const ClinicalMessagesScreen({super.key, this.patientId, this.patientName});
  final String? patientId;
  final String? patientName;
  @override
  State<ClinicalMessagesScreen> createState() => _ClinicalMessagesScreenState();
}

class _ClinicalMessagesScreenState extends State<ClinicalMessagesScreen> {
  final _text = TextEditingController();
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final Map<String, String> _drafts = {};
  String? _selected;
  String _channel = 'doctor_patient';
  String? _peer;
  List<Map<String, dynamic>> _peers = [];
  Timer? _poll;
  bool get _private =>
      _channel == 'patient_caregiver' || _channel == 'doctor_caregiver';
  bool _sending = false;
  bool _allowPop = false;
  bool _initialized = false;
  AppUser? _owner;
  String? _origin;
  bool get ar => AppLocalizations.of(context).isArabic;
  String get _draftKey => '${_selected ?? ''}:$_channel:${_peer ?? ''}';

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          !_sending &&
          !context.read<AppState>().messages.loading) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppState>();
    if (!_initialized ||
        !AppUser.sameSessionOwner(_owner, app.auth.currentUser) ||
        _origin != app.api.baseUrl) {
      _initialized = true;
      _owner = app.auth.currentUser;
      _origin = app.api.baseUrl;
      _drafts.clear();
      _text.clear();
      _selected = null;
      _peer = null;
      _peers = [];
      _allowPop = false;
      _channel = app.auth.currentUser?.role == UserRole.caregiver
          ? 'family_patient'
          : 'doctor_patient';
      final allowed = app.auth.accessiblePatients();
      final requested = app.auth.currentUser?.role == UserRole.patient
          ? app.auth.currentUser?.uid
          : widget.patientId;
      if (requested != null && app.messages.canAccess(requested)) {
        _selected = requested;
      } else if (requested == null && allowed.length == 1) {
        _selected = allowed.first.patientId;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selected != null) _refresh();
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _text.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _select(String? patient, [String? channel]) {
    if (_sending) return;
    _drafts[_draftKey] = _text.text;
    setState(() {
      if (_selected != patient) {
        _peer = null;
        _peers = [];
      }
      _selected = patient;
      _channel = channel ?? _channel;
      _text.text = _drafts[_draftKey] ?? '';
    });
    if (patient != null) _refresh();
  }

  Future<void> _refresh() async {
    final pid = _selected;
    if (pid != null) {
      final app = context.read<AppState>();
      final owner = app.auth.currentUser;
      final origin = app.api.baseUrl;
      if (app.messages.loading) return;
      try {
        final response = await app.api.sendJson(
          method: 'GET',
          path: '/patients/${Uri.encodeComponent(pid)}/message-peers',
        );
        if (!mounted ||
            _selected != pid ||
            !AppUser.sameSessionOwner(owner, app.auth.currentUser) ||
            origin != app.api.baseUrl) {
          return;
        }
        final peers = (response['peers'] as List? ?? [])
            .whereType<Map>()
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
        setState(() {
          _peers = peers;
          if (owner?.role == UserRole.caregiver) _peer = owner!.uid;
          if (_peer != null && !peers.any((p) => p['id'] == _peer)) {
            _peer = null;
          }
          if (_peer == null && peers.length == 1) {
            _peer = peers.single['id'] as String;
          }
        });
      } catch (_) {
        /* Keep the selected cached conversation during an outage. */
      }
      if (!mounted ||
          _selected != pid ||
          !AppUser.sameSessionOwner(owner, app.auth.currentUser) ||
          origin != app.api.baseUrl) {
        return;
      }
      await app.messages.loadFor(pid, channel: _channel, peerUserId: _peer);
    }
  }

  Future<void> _leave() async {
    if (_allowPop) return;
    _drafts[_draftKey] = _text.text;
    if (_drafts.values.every((text) => text.trim().isEmpty)) {
      setState(() => _allowPop = true);
    } else {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(ar ? 'مغادرة المسودات؟' : 'Leave drafts?'),
          content: Text(
            ar
                ? 'توجد رسائل لم تُحفظ بعد. المغادرة ستتجاهل هذه المسودات فقط، ولا تحذف الرسائل المحفوظة.'
                : 'Some drafts have not been saved. Leaving discards only these drafts, not saved messages.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(ar ? 'البقاء' : 'Stay'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(ar ? 'تجاهل ومغادرة' : 'Discard & leave'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
      setState(() => _allowPop = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.maybePop(context);
    });
  }

  Future<void> _send() async {
    if (_sending || _selected == null || _text.text.trim().isEmpty) return;
    final app = context.read<AppState>();
    final owner = app.auth.currentUser;
    final origin = app.api.baseUrl;
    final pid = _selected!;
    final channel = _channel;
    final content = _text.text;
    final key = _draftKey;
    setState(() => _sending = true);
    try {
      final message = await app.messages.sendMessage(
        patientId: pid,
        channelType: channel,
        peerUserId: _peer,
        content: content,
      );
      if (!mounted ||
          !AppUser.sameSessionOwner(app.auth.currentUser, owner) ||
          app.api.baseUrl != origin) {
        return;
      }
      _drafts.remove(key);
      if (_selected == pid && _channel == channel && _text.text == content) {
        _text.clear();
      }
      if (!message.synced) {
        AppSnack.show(
          context,
          ar
              ? 'حُفظت الرسالة على الجهاز؛ بانتظار قبول الخادم.'
              : 'Message saved on this device; awaiting server acceptance.',
        );
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: AppMotion.duration(context),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (error) {
      if (mounted) {
        AppSnack.error(
          context,
          Failure.from(error).message(AppLocalizations.of(context)),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l = AppLocalizations.of(context);
    final allowed = app.auth.accessiblePatients();
    final isPatient = app.auth.currentUser?.role == UserRole.patient;
    final isCaregiver = app.auth.currentUser?.role == UserRole.caregiver;
    final valid =
        _selected != null &&
        app.messages.canAccess(_selected!, channel: _channel) &&
        (!_private || _peer != null);
    final profile = valid ? app.auth.patientById(_selected!) : null;
    return PopScope(
      canPop:
          _allowPop ||
          (_text.text.trim().isEmpty &&
              _drafts.values.every((value) => value.trim().isEmpty)),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.messagesTitle),
          actions: [
            if (valid)
              IconButton(
                tooltip: l.refresh,
                onPressed: _sending || app.messages.loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = !isPatient && constraints.maxWidth >= 1000;
            Widget inbox() => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      labelText: ar ? 'بحث عن مريض' : 'Search patients',
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Expanded(
                  child: allowed.isEmpty
                      ? EmptyState(title: l.noLinkedPatients)
                      : ListView(
                          children: allowed
                              .where(
                                (p) => p.name.toLowerCase().contains(
                                  _search.text.trim().toLowerCase(),
                                ),
                              )
                              .map(
                                (p) => ListTile(
                                  leading: const CircleAvatar(
                                    child: Icon(Icons.person_outline),
                                  ),
                                  title: Text(p.name),
                                  selected: _selected == p.patientId,
                                  onTap: _sending
                                      ? null
                                      : () => _select(p.patientId),
                                ),
                              )
                              .toList(),
                        ),
                ),
              ],
            );
            if (!isPatient && (!valid || wide)) {
              return Row(
                children: [
                  if (wide)
                    SizedBox(width: 300, child: inbox())
                  else
                    Expanded(child: inbox()),
                  if (wide) ...[
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: valid
                          ? chat(
                              app,
                              profile?.name ?? '',
                              isPatient,
                              isCaregiver,
                            )
                          : EmptyState(
                              title: ar
                                  ? 'اختر المريض لبدء المحادثة'
                                  : 'Choose a patient to start a conversation',
                            ),
                    ),
                  ],
                ],
              );
            }
            if (!valid) {
              return EmptyState(
                title: ar
                    ? 'المحادثة غير متاحة لهذا الحساب'
                    : 'This conversation is unavailable for this account',
              );
            }
            return ResponsiveContent(
              maxWidth: 1000,
              child: chat(app, profile?.name ?? '', isPatient, isCaregiver),
            );
          },
        ),
      ),
    );
  }

  Widget chat(AppState app, String name, bool patient, bool caregiver) {
    final loaded = app.messages.patientId == _selected;
    final doctor = app.auth.currentUser?.role == UserRole.doctor;
    final messages = loaded
        ? app.messages
              .messagesFor(_channel)
              .where(
                (m) => m.patientId == _selected && m.channelType == _channel,
              )
              .toList()
        : <ChatMessage>[];
    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(14),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: AppColors.accent(
                                  context,
                                  AccentTone.blue,
                                ).container,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.person_rounded,
                                color: Theme.of(context).colorScheme.primary,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                name,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                              ),
                            ),
                            if (!patient)
                              IconButton(
                                tooltip: ar ? 'تغيير المريض' : 'Change patient',
                                onPressed: _sending
                                    ? null
                                    : () => _select(null),
                                icon: Icon(
                                  Icons.people_outline_rounded,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.accent(
                              context,
                              AccentTone.orange,
                            ).container,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: AppColors.of(
                                context,
                                RiskView.caution,
                              ).border,
                            ),
                          ),
                          child: Text(
                            ar
                                ? 'الرسائل ليست قناة للطوارئ.'
                                : 'Messages are not an emergency channel.',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFC2410C),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (!caregiver)
                              ChoiceChip(
                                label: Text(
                                  ar ? 'الطبيب والمريض' : 'Doctor & patient',
                                ),
                                selected: _channel == 'doctor_patient',
                                onSelected: _sending
                                    ? null
                                    : (_) =>
                                          _select(_selected, 'doctor_patient'),
                              ),
                            ChoiceChip(
                              tooltip: ar
                                  ? 'مجموعة مشتركة تضم المريض والطبيب المعالج والمرافق الأسري'
                                  : 'Shared group for patient, doctor, and family caregiver',
                              label: Text(ar ? 'دائرة الرعاية' : 'Care circle'),
                              selected: _channel == 'family_patient',
                              onSelected: _sending
                                  ? null
                                  : (_) => _select(_selected, 'family_patient'),
                            ),
                            if (patient || caregiver)
                              ChoiceChip(
                                label: Text(
                                  ar
                                      ? 'المريض والمرافق'
                                      : 'Patient & caregiver',
                                ),
                                selected: _channel == 'patient_caregiver',
                                onSelected: _sending
                                    ? null
                                    : (_) => _select(
                                        _selected,
                                        'patient_caregiver',
                                      ),
                              ),
                            if (doctor || caregiver)
                              ChoiceChip(
                                label: Text(
                                  ar ? 'الطبيب والمرافق' : 'Doctor & caregiver',
                                ),
                                selected: _channel == 'doctor_caregiver',
                                onSelected: _sending
                                    ? null
                                    : (_) => _select(
                                        _selected,
                                        'doctor_caregiver',
                                      ),
                              ),
                          ],
                        ),
                        if (_private && !caregiver) ...[
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            key: ValueKey('$_selected:$_channel:$_peer'),
                            initialValue: _peer,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: ar
                                  ? 'المرافق في المحادثة الخاصة'
                                  : 'Caregiver in this private conversation',
                            ),
                            items: _peers
                                .map(
                                  (p) => DropdownMenuItem(
                                    value: p['id'] as String,
                                    child: Text(p['name'] as String),
                                  ),
                                )
                                .toList(),
                            onChanged: _sending
                                ? null
                                : (value) {
                                    _drafts[_draftKey] = _text.text;
                                    setState(() {
                                      _peer = value;
                                      _text.text = _drafts[_draftKey] ?? '';
                                    });
                                    unawaited(_refresh());
                                  },
                          ),
                        ],
                        if (loaded && app.messages.loading) ...[
                          const SizedBox(height: 10),
                          const LinearProgressIndicator(),
                        ],
                        if (loaded && app.messages.failure != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            ar
                                ? 'تعذر تحديث المحادثة؛ المعروض هو المحفوظ محليًا.'
                                : 'Unable to refresh; showing local records.',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.of(
                                context,
                                RiskView.danger,
                              ).foreground,
                            ),
                          ),
                          TextButton(
                            onPressed: _sending
                                ? null
                                : () async {
                                    await app.messages.flushPendingMessages();
                                    await _refresh();
                                  },
                            child: Text(ar ? 'إعادة المحاولة' : 'Retry'),
                          ),
                        ],
                        if (_channel == 'family_patient') ...[
                          const SizedBox(height: 6),
                          TextButton.icon(
                            icon: Icon(
                              Icons.location_on_rounded,
                              color: Theme.of(context).colorScheme.primary,
                              size: 20,
                            ),
                            label: Text(
                              ar ? 'آخر موقع مشترك' : 'Last shared location',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            onPressed: () => showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              builder: (_) => SafeArea(
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.all(20),
                                  child: PatientLocationCard(
                                    patientId: _selected!,
                                    patientName: name,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (messages.isEmpty)
                SliverToBoxAdapter(
                  child: EmptyState(
                    title: ar ? 'لا توجد رسائل محفوظة' : 'No saved messages',
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: messages.length,
                  itemBuilder: (_, i) => _MessageBubble(
                    message: messages[i],
                    own: messages[i].senderId == app.auth.currentUser?.uid,
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 1.2,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      enabled: !_sending,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 5000,
                      textInputAction: TextInputAction.newline,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: ar ? 'اكتب رسالة' : 'Write a message',
                        counterText: '',
                        filled: true,
                        // Theme-aware fill (was a fixed near-white #F8FAFC
                        // that stayed bright in dark mode).
                        fillColor:
                            Theme.of(context).brightness == Brightness.dark
                            ? Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest
                            : Theme.of(
                                context,
                              ).colorScheme.surfaceContainerLowest,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: _sending || _text.text.trim().isEmpty
                          ? const Color(0xFFCBD5E1)
                          : Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      tooltip: ar ? 'إرسال الرسالة' : 'Send message',
                      padding: EdgeInsets.zero,
                      onPressed: _sending || _text.text.trim().isEmpty
                          ? null
                          : _send,
                      icon: Icon(
                        _sending ? Icons.hourglass_top : Icons.send_rounded,
                        color: Theme.of(context).colorScheme.onPrimary,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.own});
  final ChatMessage message;
  final bool own;
  @override
  Widget build(BuildContext context) {
    final ar = AppLocalizations.of(context).isArabic;
    return Align(
      alignment: own
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: own
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(own ? 18 : 4),
              bottomRight: Radius.circular(own ? 4 : 18),
            ),
            border: own
                ? null
                : Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    width: 1.2,
                  ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x06000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                DoctorTitleFormatter.format(
                  message.senderName,
                  role: message.senderRole,
                  isArabic: ar,
                ),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: own
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              SelectableText(
                message.content,
                style: TextStyle(
                  fontSize: 15,
                  color: own
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurface,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 2,
                children: [
                  Text(
                    TimeAgo.stamp(message.createdAt),
                    style: TextStyle(
                      fontSize: 11,
                      color: own
                          ? Theme.of(
                              context,
                            ).colorScheme.onPrimary.withValues(alpha: .8)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (own)
                    Text(
                      message.readAt != null
                          ? (ar ? 'قُرئت' : 'Read')
                          : message.synced
                          ? (ar ? 'قبله الخادم' : 'Accepted by server')
                          : (ar
                                ? 'محفوظ محليًا · بانتظار الإرسال'
                                : 'Saved locally · pending'),
                      style: TextStyle(
                        fontSize: 11,
                        color: own
                            ? const Color(0xFFBFDBFE)
                            : Theme.of(context).colorScheme.onSurfaceVariant,
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
