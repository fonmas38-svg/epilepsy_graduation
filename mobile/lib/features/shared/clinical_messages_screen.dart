import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/enums.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/states.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/app_state.dart';

/// Clinical & Family Communication Screen with strict channel privacy.
class ClinicalMessagesScreen extends StatefulWidget {
  const ClinicalMessagesScreen({
    super.key,
    this.patientId,
    this.patientName,
  });

  final String? patientId;
  final String? patientName;

  @override
  State<ClinicalMessagesScreen> createState() => _ClinicalMessagesScreenState();
}

class _ClinicalMessagesScreenState extends State<ClinicalMessagesScreen>
    with SingleTickerProviderStateMixin {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  TabController? _tabController;
  String _activeChannel = 'doctor_patient';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  void _init() {
    final app = context.read<AppState>();
    final role = app.auth.currentUser?.role ?? UserRole.patient;
    final pid = _resolvePatientId(app);

    if (role == UserRole.caregiver) {
      _activeChannel = 'family_patient';
    } else if (role == UserRole.patient) {
      _tabController = TabController(length: 2, vsync: this);
      _tabController!.addListener(() {
        if (_tabController!.indexIsChanging) return;
        setState(() {
          _activeChannel =
              _tabController!.index == 0 ? 'doctor_patient' : 'family_patient';
        });
      });
      _activeChannel = 'doctor_patient';
    } else {
      // Doctor defaults to doctor_patient
      _activeChannel = 'doctor_patient';
    }

    if (pid != null) {
      app.messages.loadFor(pid);
    }
  }

  String? _resolvePatientId(AppState app) {
    if (widget.patientId != null && widget.patientId!.isNotEmpty) {
      return widget.patientId;
    }
    final user = app.auth.currentUser;
    if (user?.role == UserRole.patient) {
      return user?.uid;
    }
    return app.activePatientId ?? app.auth.accessiblePatients().firstOrNull?.patientId;
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _tabController?.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final app = context.read<AppState>();
    final pid = _resolvePatientId(app);
    if (pid == null) return;

    _textController.clear();
    await app.messages.sendMessage(
      patientId: pid,
      channelType: _activeChannel,
      content: text,
    );

    // Scroll to bottom
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 80,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final user = app.auth.currentUser;
    final role = user?.role ?? UserRole.patient;
    final pname = widget.patientName ?? user?.name ?? 'المريض';

    final isCaregiver = role == UserRole.caregiver;
    final isPatient = role == UserRole.patient;

    final messagesList = _activeChannel == 'doctor_patient'
        ? app.messages.doctorMessages
        : app.messages.familyMessages;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isCaregiver
                  ? 'محادثة الأسرة — $pname'
                  : '${l.messagesTitle} — $pname',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              _activeChannel == 'doctor_patient'
                  ? 'قناة خاصة ومشفرة بين الطبيب والمريض فقط'
                  : 'قناة رعاية وتواصل الأسرة والمرافقين',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        bottom: isPatient && _tabController != null
            ? TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(
                    icon: Icon(Icons.medical_services_outlined, size: 18),
                    text: 'استشارات الطبيب (خاصة)',
                  ),
                  Tab(
                    icon: Icon(Icons.family_restroom_outlined, size: 18),
                    text: 'محادثات الأسرة',
                  ),
                ],
              )
            : null,
      ),
      body: Column(
        children: [
          // Privacy Notice Banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
            color: _activeChannel == 'doctor_patient'
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
                : theme.colorScheme.secondaryContainer.withValues(alpha: 0.4),
            child: Row(
              children: [
                Icon(
                  _activeChannel == 'doctor_patient'
                      ? Icons.lock_outline
                      : Icons.people_outline,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                Gap.hSm,
                Expanded(
                  child: Text(
                    _activeChannel == 'doctor_patient'
                        ? 'محادثة سرية محمية: لا تظهر لأفراد الأسرة ضماناً للسرية الطبية.'
                        : 'قناة الأسرة: يشارك فيها المريض وأفراد أسرته لمتابعة الحالة اليومية.',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),

          // Message stream
          Expanded(
            child: messagesList.isEmpty
                ? EmptyState(
                    icon: Icons.chat_bubble_outline,
                    title: _activeChannel == 'doctor_patient'
                        ? 'لا توجد رسائل مع الطبيب بعد'
                        : 'لا توجد رسائل عائلية بعد',
                    body: 'اكتب رسالتك بالأسفل لبدء المحادثة بشكل مباشر وآمن.',
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(Gap.md),
                    itemCount: messagesList.length,
                    itemBuilder: (context, index) {
                      final msg = messagesList[index];
                      final isMe = msg.senderId == user?.uid;
                      return _MessageBubble(
                        message: msg,
                        isMe: isMe,
                      );
                    },
                  ),
          ),

          // Input field
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: InputDecoration(
                        hintText: _activeChannel == 'doctor_patient'
                            ? 'اكتب استشارتك أو توجيهك الطبي...'
                            : 'اكتب رسالتك لأفراد الأسرة...',
                        border: InputBorder.none,
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  IconButton(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send_rounded),
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isMe,
  });

  final ChatMessage message;
  final bool isMe;

  Future<void> _openMap(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLocation = message.content.contains('maps.google.com');

    final roleLabel = switch (message.senderRole) {
      UserRole.doctor => 'دكتور',
      UserRole.caregiver => 'مرافق',
      UserRole.patient => 'مريض',
    };

    return Align(
      alignment: isMe ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: Gap.sm),
        padding: const EdgeInsets.all(Gap.md),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: isMe
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
          border: isLocation ? Border.all(color: Colors.green, width: 1.5) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.senderName,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isMe
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Gap.hXs,
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: isMe
                        ? theme.colorScheme.primary.withValues(alpha: 0.15)
                        : theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Text(
                    roleLabel,
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              message.content,
              style: theme.textTheme.bodyMedium,
            ),
            if (isLocation) ...[
              Gap.vSm,
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  final match = RegExp(r'https://maps\.google\.com[^\s]+').firstMatch(message.content);
                  if (match != null) {
                    _openMap(match.group(0)!);
                  }
                },
                icon: const Icon(Icons.map, size: 16),
                label: const Text('فتح الموقع في Google Maps'),
              ),
            ],
            const SizedBox(height: Gap.xs),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  '${message.createdAt.hour}:${message.createdAt.minute.toString().padLeft(2, '0')}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isMe) ...[
                  Gap.hXs,
                  Icon(
                    message.synced ? Icons.done_all : Icons.access_time,
                    size: 12,
                    color: message.synced
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
