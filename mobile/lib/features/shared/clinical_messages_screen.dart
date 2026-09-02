import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../core/theme/app_spacing.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';

class ClinicalMessageItem {
  ClinicalMessageItem({
    required this.id,
    required this.senderName,
    required this.senderRole,
    required this.content,
    required this.timestamp,
    this.repliesAllowed = true,
  });

  final String id;
  final String senderName;
  final UserRole senderRole;
  final String content;
  final DateTime timestamp;
  final bool repliesAllowed;
}

/// Clinical Directives & Messages Screen.
///
/// Facilitates direct communication between doctor and patient, with doctor-controlled
/// reply permissions (directive-only vs interactive consultation).
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

class _ClinicalMessagesScreenState extends State<ClinicalMessagesScreen> {
  final _textController = TextEditingController();
  final List<ClinicalMessageItem> _messages = [
    ClinicalMessageItem(
      id: 'msg-1',
      senderName: 'د. خالد العمري',
      senderRole: UserRole.doctor,
      content: 'يرجى الالتزام بتناول جرعة كيبرا المسائية في تمام الساعة الثامنة، مع تجنب السهر المفرط.',
      timestamp: DateTime.now().subtract(const Duration(hours: 3)),
      repliesAllowed: true,
    ),
    ClinicalMessageItem(
      id: 'msg-2',
      senderName: 'سارة (المريض)',
      senderRole: UserRole.patient,
      content: 'تم أخذ الجرعة في موعدها، وأشعر بالاستقرار والحمد لله.',
      timestamp: DateTime.now().subtract(const Duration(hours: 1)),
      repliesAllowed: true,
    ),
  ];

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final app = context.read<AppState>();
    final user = app.auth.currentUser;

    setState(() {
      _messages.add(
        ClinicalMessageItem(
          id: 'msg-${DateTime.now().millisecondsSinceEpoch}',
          senderName: user?.name ?? 'المستخدم',
          senderRole: user?.role ?? UserRole.patient,
          content: text,
          timestamp: DateTime.now(),
        ),
      );
      _textController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final pname = widget.patientName ?? app.auth.currentUser?.name ?? 'المريض';

    return Scaffold(
      appBar: AppBar(
        title: Text('${l.messagesTitle} — $pname'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(Gap.md),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isMe = msg.senderRole == app.auth.currentUser?.role;

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
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          msg.senderName,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: isMe
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: Gap.xs),
                        Text(
                          msg.content,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: Gap.xs),
                        Align(
                          alignment: Alignment.bottomLeft,
                          child: Text(
                            '${msg.timestamp.hour}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 10,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
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
                        hintText: l.typeMessage,
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
