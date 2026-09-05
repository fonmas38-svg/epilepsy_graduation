import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/enums.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/states.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';

/// Clinical & Family Communication Screen with WhatsApp-style Conversation Hub.
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
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  TabController? _tabController;

  String? _selectedPatientId;
  String? _selectedPatientName;
  String _activeChannel = 'doctor_patient';
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _selectedPatientId = widget.patientId;
    _selectedPatientName = widget.patientName;
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  void _init() {
    final app = context.read<AppState>();
    final user = app.auth.currentUser;
    final role = user?.role ?? UserRole.patient;

    if (role == UserRole.caregiver) {
      _activeChannel = 'family_patient';
      _selectedPatientId ??= _resolveInitialPatientId(app);
    } else if (role == UserRole.patient) {
      _selectedPatientId = user?.uid;
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
      // Doctor role
      _activeChannel = 'doctor_patient';
      // If no explicit patientId passed, let doctor choose from conversation list
      if (_selectedPatientId != null) {
        final p = app.auth.patientById(_selectedPatientId!);
        _selectedPatientName = p?.name ?? widget.patientName;
      }
    }

    if (_selectedPatientId != null) {
      app.messages.loadFor(_selectedPatientId!);
    }
  }

  String? _resolveInitialPatientId(AppState app) {
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
    _searchController.dispose();
    _scrollController.dispose();
    _tabController?.dispose();
    super.dispose();
  }

  void _selectPatient(PatientProfile p, {String channel = 'doctor_patient'}) {
    setState(() {
      _selectedPatientId = p.patientId;
      _selectedPatientName = p.name;
      _activeChannel = channel;
    });
    context.read<AppState>().messages.loadFor(p.patientId);
  }

  Future<void> _sendMessage([String? quickText]) async {
    final text = (quickText ?? _textController.text).trim();
    if (text.isEmpty) return;

    final app = context.read<AppState>();
    final pid = _selectedPatientId ?? _resolveInitialPatientId(app);
    if (pid == null) return;

    if (quickText == null) {
      _textController.clear();
    }
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

    final isDoctor = role == UserRole.doctor;
    final isPatient = role == UserRole.patient;

    final mediaWidth = MediaQuery.of(context).size.width;
    final isWideScreen = mediaWidth >= 880;

    // Doctor conversation hub navigation
    if (isDoctor && !isWideScreen && _selectedPatientId == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(l.doctorInboxTitle),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _buildSearchBar(theme, l),
            ),
          ),
        ),
        body: _buildDoctorInboxList(app, theme, l),
      );
    }

    if (isDoctor && isWideScreen) {
      return Scaffold(
        appBar: AppBar(
          title: Text('${l.doctorInboxTitle} • درع الأعصاب الذكي'),
        ),
        body: Row(
          children: [
            // Left Pane: WhatsApp-style conversation list
            SizedBox(
              width: 340,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: _buildSearchBar(theme, l),
                  ),
                  const Divider(height: 1),
                  Expanded(child: _buildDoctorInboxList(app, theme, l)),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            // Right Pane: Active Chat
            Expanded(
              child: _selectedPatientId == null
                  ? _buildEmptyConversationPlaceholder(theme, l)
                  : _buildChatArea(context, app, theme, l, isDoctor, isPatient),
            ),
          ],
        ),
      );
    }

    // Standard single-chat view (Mobile for Patient, Caregiver, or Doctor with selected patient)
    final pname = _selectedPatientName ?? widget.patientName ?? user?.name ?? 'المريض';
    return Scaffold(
      appBar: AppBar(
        leading: isDoctor
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'العودة لصندوق المحادثات',
                onPressed: () => setState(() => _selectedPatientId = null),
              )
            : null,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isDoctor
                  ? 'محادثة: $pname'
                  : role == UserRole.caregiver
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
        actions: [
          if (isDoctor)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'doctor_patient',
                    icon: Icon(Icons.person_outline, size: 16),
                    label: Text('المريض', style: TextStyle(fontSize: 11.5)),
                  ),
                  ButtonSegment(
                    value: 'family_patient',
                    icon: Icon(Icons.group_outlined, size: 16),
                    label: Text('الأسرة', style: TextStyle(fontSize: 11.5)),
                  ),
                ],
                selected: {_activeChannel},
                onSelectionChanged: (set) {
                  setState(() => _activeChannel = set.first);
                },
              ),
            ),
        ],
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
      body: _buildChatArea(context, app, theme, l, isDoctor, isPatient),
    );
  }

  Widget _buildSearchBar(ThemeData theme, AppLocalizations l) {
    return TextField(
      controller: _searchController,
      decoration: InputDecoration(
        hintText: l.searchPatientsAndFamily,
        prefixIcon: const Icon(Icons.search, size: 20),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
    );
  }

  Widget _buildDoctorInboxList(AppState app, ThemeData theme, AppLocalizations l) {
    final patients = app.auth.accessiblePatients().where((p) {
      if (_searchQuery.isEmpty) return true;
      return p.name.toLowerCase().contains(_searchQuery) ||
          p.patientId.toLowerCase().contains(_searchQuery) ||
          p.diagnosis.toLowerCase().contains(_searchQuery);
    }).toList();

    if (patients.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: EmptyState(
            icon: Icons.person_search_outlined,
            title: l.noConversationsFound,
            body: 'لم يتم العثور على مرضى أو أسر تطابق البحث.',
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: patients.length,
      separatorBuilder: (_, i) => const Divider(height: 1, indent: 70),
      itemBuilder: (context, index) {
        final p = patients[index];
        final isSelected = p.patientId == _selectedPatientId;
        final risk = p.currentStatus;
        final riskColor = switch (risk) {
          RiskLabel.highRisk => const Color(0xFFEF4444),
          RiskLabel.watch => const Color(0xFFF59E0B),
          RiskLabel.stable => const Color(0xFF10B981),
        };

        return ListTile(
          selected: isSelected,
          selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          leading: Stack(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: const Color(0xFF0284C7).withValues(alpha: 0.15),
                child: Text(
                  p.name.isNotEmpty ? p.name.substring(0, 1) : 'م',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: riskColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.scaffoldBackgroundColor, width: 2),
                  ),
                ),
              ),
            ],
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  p.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                'نشط',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 2),
              Text(
                p.diagnosis,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  InkWell(
                    onTap: () => _selectPatient(p, channel: 'doctor_patient'),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0284C7).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.person, size: 12, color: Color(0xFF0284C7)),
                          SizedBox(width: 4),
                          Text(
                            'محادثة المريض',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: Color(0xFF0284C7),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _selectPatient(p, channel: 'family_patient'),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.family_restroom, size: 12, color: Color(0xFF10B981)),
                          SizedBox(width: 4),
                          Text(
                            'محادثة الأسرة',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: Color(0xFF10B981),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          onTap: () => _selectPatient(p, channel: 'doctor_patient'),
        );
      },
    );
  }

  Widget _buildEmptyConversationPlaceholder(ThemeData theme, AppLocalizations l) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF0284C7).withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.forum_outlined,
              size: 64,
              color: Color(0xFF0284C7),
            ),
          ),
          Gap.vMd,
          Text(
            'صندوق المحادثات والاستشارات السريرية',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          Gap.vSm,
          Text(
            'اختر مريضاً أو أسرة من القائمة الجانبية لبدء المحادثة الفورية الآمنة.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildChatArea(
    BuildContext context,
    AppState app,
    ThemeData theme,
    AppLocalizations l,
    bool isDoctor,
    bool isPatient,
  ) {
    final user = app.auth.currentUser;
    final messagesList = _activeChannel == 'doctor_patient'
        ? app.messages.doctorMessages
        : app.messages.familyMessages;

    final quickReplies = isDoctor
        ? [
            'يرجى الالتزام بموعد الدواء المجدول.',
            'كيف تشعر الآن؟ هل لاحظت أي أعراض مسبقة؟',
            'المؤشرات الفسيولوجية مستقرة تماماً والحمد لله.',
            'يرجى مراجعة العيادة لمتابعة الفحص السريري.',
          ]
        : [
            'أنا بخير تماماً والحمد لله.',
            'تناولت جرعة الدواء في موعدها.',
            'أشعر ببعض الإرهاق وأرتاح الآن.',
          ];

    return Column(
      children: [
        // Privacy Notice Banner
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
          color: _activeChannel == 'doctor_patient'
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
              : theme.colorScheme.secondaryContainer.withValues(alpha: 0.35),
          child: Row(
            children: [
              Icon(
                _activeChannel == 'doctor_patient' ? Icons.lock_outline : Icons.people_outline,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              Gap.hSm,
              Expanded(
                child: Text(
                  _activeChannel == 'doctor_patient'
                      ? 'محادثة سرية محمية: قناة خاصة بين الطبيب والمريض فقط.'
                      : 'قناة الأسرة والمرافق: تواصل مشترك بين المريض ومرافقه السريري.',
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

        // Quick Clinical Templates
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: quickReplies.length,
            separatorBuilder: (_, i) => const SizedBox(width: Gap.xs),
            itemBuilder: (context, i) {
              return ActionChip(
                label: Text(quickReplies[i], style: const TextStyle(fontSize: 11)),
                onPressed: () => _sendMessage(quickReplies[i]),
                visualDensity: VisualDensity.compact,
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
                          ? 'اكتب توجيهك الطبي أو استشارتك...'
                          : 'اكتب رسالتك لأفراد الأسرة والمرافق...',
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                IconButton(
                  onPressed: () => _sendMessage(),
                  icon: const Icon(Icons.send_rounded),
                  color: theme.colorScheme.primary,
                ),
              ],
            ),
          ),
        ),
      ],
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
      UserRole.doctor => 'طبيب معالج',
      UserRole.caregiver => 'مرافق أسري',
      UserRole.patient => 'مريض',
      UserRole.admin => 'مدير النظام',
    };

    return Align(
      alignment: isMe ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: Gap.sm),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 360),
        decoration: BoxDecoration(
          color: isMe
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
          border: isLocation ? Border.all(color: Colors.green, width: 1.5) : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
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
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: isMe
                        ? theme.colorScheme.primary.withValues(alpha: 0.18)
                        : theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Text(
                    roleLabel,
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 9.5, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              message.content,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
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
                    size: 13,
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
