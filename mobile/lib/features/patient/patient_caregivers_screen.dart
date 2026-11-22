import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/enums.dart';
import '../../core/errors/failure.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';

class PatientCaregiversScreen extends StatefulWidget {
  const PatientCaregiversScreen({super.key});
  @override
  State<PatientCaregiversScreen> createState() =>
      _PatientCaregiversScreenState();
}

class _PatientCaregiversScreenState extends State<PatientCaregiversScreen> {
  AppUser? _owner;
  String? _origin;
  List<Map<String, dynamic>> _members = [];
  bool _loading = false, _busy = false, _loaded = false;
  String? _error;
  bool get ar => AppLocalizations.of(context).isArabic;
  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _owner = app.auth.currentUser;
    _origin = app.api.baseUrl;
    _load();
  }

  bool _current() {
    if (!mounted) return false;
    final app = context.read<AppState>();
    return AppUser.sameSessionOwner(app.auth.currentUser, _owner) &&
        app.api.baseUrl == _origin &&
        app.auth.currentUser?.role == UserRole.patient;
  }

  Future<void> _load() async {
    if (!_current() || _loading || _busy) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final body = await context.read<AppState>().api.getObject(
        '/patient/caregivers',
      );
      if (body['caregivers'] is! List) {
        throw const FormatException('Missing caregivers');
      }
      final members = (body['caregivers'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      if (_current()) {
        setState(() {
          _members = members;
          _loaded = true;
        });
      }
    } catch (error) {
      if (_current()) {
        setState(() {
          _error = Failure.from(error).message(AppLocalizations.of(context));
          _loaded = false;
        });
      }
    } finally {
      if (_current()) setState(() => _loading = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? member]) async {
    if (_busy || !_loaded || !_current()) return;
    final app = context.read<AppState>();
    setState(() => _busy = true);
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CaregiverEditor(
        member: member,
        isCurrent: _current,
        save: (body) async {
          if (!_current()) throw const Failure(FailureKind.unauthorized);
          final path = member == null
              ? '/patient/caregivers'
              : '/patient/caregivers/${Uri.encodeComponent(member['id'] as String)}';
          final result = await app.api.sendJson(
            method: member == null ? 'POST' : 'PATCH',
            path: path,
            body: body,
          );
          if (!_current()) throw const Failure(FailureKind.unauthorized);
          if (result['caregiver'] is! Map) {
            throw const FormatException('Missing saved caregiver');
          }
          return result;
        },
      ),
    );
    if (!_current()) return;
    setState(() => _busy = false);
    if (saved == true && mounted) {
      AppSnack.success(
        context,
        ar ? 'حُفظت بيانات المرافق' : 'Caregiver saved',
      );
    }
    await _load();
  }

  Future<void> _toggle(Map<String, dynamic> member) async {
    final api = context.read<AppState>().api;
    if (!_current() || _busy || !_loaded || member['accountDisabled'] == true) {
      return;
    }
    final enable = member['disabled'] == true;
    final title = enable
        ? (ar ? 'تفعيل الوصول' : 'Enable access')
        : (ar ? 'إيقاف الوصول' : 'Disable access');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(
          '${member['name']}\n${ar ? 'يؤثر التغيير على وصول المرافق لهذا المريض فقط، ولا يعطّل حسابه أو روابطه بمرضى آخرين. لا يمكن سحب بيانات أو إشعارات سبق تسليمها.' : 'This changes access to this patient only. It does not disable the account or its links to other patients. Previously delivered data or notifications cannot be recalled.'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(title),
          ),
        ],
      ),
    );
    if (accepted != true || !_current() || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.sendJson(
        method: 'POST',
        path:
            '/patient/caregivers/${Uri.encodeComponent(member['id'] as String)}/${enable ? 'enable' : 'disable'}',
      );
      if (!_current()) return;
    } catch (error) {
      if (_current()) {
        setState(() {
          _loaded = false;
          _error = Failure.from(error).message(AppLocalizations.of(context));
        });
      }
    } finally {
      if (_current()) setState(() => _busy = false);
    }
    if (_current() && _loaded) await _load();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    if (!_current()) return const SizedBox.shrink();
    final enabled = _loaded && !_busy && !_loading;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F9FD),
      appBar: AppBar(
        title: Text(
          ar ? 'المرافقون' : 'Caregivers',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF0D253C),
            fontSize: 19,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF0D253C)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE4EDF7), height: 1),
        ),
        actions: [
          IconButton(
            tooltip: ar ? 'تحديث القائمة' : 'Refresh list',
            onPressed: _busy || _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ResponsiveContent(
        maxWidth: 860,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          children: [
            Text(
              ar ? 'قائمة مقدمي الرعاية' : 'Caregiver List',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0D253C),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              ar
                  ? 'إدارة حسابات المرافقين المرتبطين بك. وصول التنبيهات يعتمد على إعداد القنوات واتصال أجهزتهم.'
                  : 'Manage caregivers linked to you. Notification delivery depends on channel setup and device connectivity.',
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF64748B),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0066FF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                onPressed: enabled ? () => _edit() : null,
                icon: const Icon(Icons.person_add_rounded, size: 20),
                label: Text(
                  ar ? 'إضافة مرافق' : 'Add caregiver',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
            if (_loading || _busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: LinearProgressIndicator(),
              ),
            if (_error != null) ...[
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: _busy || _loading ? null : _load,
                child: Text(ar ? 'إعادة المحاولة' : 'Retry'),
              ),
            ],
            if (_loaded) ...[
              if (_members.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: Text(
                      ar ? 'لا يوجد مرافقون مرتبطون بك' : 'No linked caregivers',
                      style: const TextStyle(color: Color(0xFF64748B)),
                    ),
                  ),
                ),
              ..._members.map(
                (member) {
                  final isDisabled = member['disabled'] == true;
                  final isAccountDisabled = member['accountDisabled'] == true;
                  return Container(
                    margin: const EdgeInsets.only(top: 14),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFE4EDF7), width: 1.2),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x06000000),
                          blurRadius: 8,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEFF6FF),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Icon(
                                Icons.person_rounded,
                                color: Color(0xFF0066FF),
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${member['name'] ?? member['username'] ?? ''}',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0D253C),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '@${member['username'] ?? ''}'
                                    '${member['relation'] != null && '${member['relation']}'.isNotEmpty ? ' · ${member['relation']}' : ''}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: isAccountDisabled || isDisabled
                                    ? const Color(0xFFFFF1F2)
                                    : const Color(0xFFECFDF5),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: isAccountDisabled || isDisabled
                                      ? const Color(0xFFFECDD3)
                                      : const Color(0xFFA7F3D0),
                                ),
                              ),
                              child: Text(
                                isAccountDisabled
                                    ? (ar ? 'معطل' : 'Disabled')
                                    : isDisabled
                                    ? (ar ? 'وصوله إليك متوقف' : 'Access paused')
                                    : (ar ? 'نشط' : 'Active'),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isAccountDisabled || isDisabled
                                      ? const Color(0xFFE11D48)
                                      : const Color(0xFF059669),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (member['phone'] != null && '${member['phone']}'.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              const Icon(Icons.phone_outlined, size: 16, color: Color(0xFF64748B)),
                              const SizedBox(width: 6),
                              Text(
                                '${member['phone']}',
                                textDirection: TextDirection.ltr,
                                style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 14),
                        const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                side: const BorderSide(color: Color(0xFFE4EDF7)),
                              ),
                              onPressed: enabled && member['disabled'] != true
                                  ? () => _edit(member)
                                  : null,
                              icon: const Icon(Icons.edit_outlined, size: 16),
                              label: Text(
                                ar ? 'تعديل البيانات' : 'Edit details',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                side: BorderSide(
                                  color: isDisabled
                                      ? const Color(0xFF0066FF)
                                      : const Color(0xFFE4EDF7),
                                ),
                              ),
                              onPressed: enabled && member['accountDisabled'] != true
                                  ? () => _toggle(member)
                                  : null,
                              icon: Icon(
                                isDisabled ? Icons.play_arrow_rounded : Icons.pause_rounded,
                                size: 16,
                                color: isDisabled ? const Color(0xFF0066FF) : null,
                              ),
                              label: Text(
                                isDisabled
                                    ? (ar ? 'تفعيل الوصول' : 'Enable access')
                                    : (ar ? 'إيقاف الوصول' : 'Disable access'),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDisabled ? const Color(0xFF0066FF) : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class CaregiverEditor extends StatefulWidget {
  const CaregiverEditor({
    super.key,
    this.member,
    required this.save,
    required this.isCurrent,
  });
  final Map<String, dynamic>? member;
  final Future<Map<String, dynamic>> Function(Map<String, Object?>) save;
  final bool Function() isCurrent;
  @override
  State<CaregiverEditor> createState() => _CaregiverEditorState();
}

class _CaregiverEditorState extends State<CaregiverEditor> {
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  bool _busy = false;
  String? _error, _generated;
  bool get ar => AppLocalizations.of(context).isArabic;
  @override
  void initState() {
    super.initState();
    for (final field in ['name', 'username', 'phone', 'relation', 'password']) {
      _controllers[field] = TextEditingController(
        text: widget.member?[field]?.toString() ?? '',
      );
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _close() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isCurrent()) Navigator.pop(context, true);
    });
  }

  Future<void> _save() async {
    if (_busy || !widget.isCurrent() || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = <String, Object?>{};
      for (final field in ['name', 'phone', 'relation']) {
        body[field] = _controllers[field]!.text.trim();
      }
      if (widget.member == null) {
        body['username'] = _controllers['username']!.text.trim();
        if (_controllers['password']!.text.isNotEmpty) {
          body['password'] = _controllers['password']!.text;
        }
      }
      final response = await widget.save(body);
      if (!mounted || !widget.isCurrent()) return;
      setState(() {
        _busy = false;
        _generated = response['generatedPassword'] as String?;
      });
      if (_generated == null) _close();
    } catch (error) {
      if (!mounted || !widget.isCurrent()) return;
      final failure = Failure.from(error);
      setState(() {
        _busy = false;
        _error = failure.kind == FailureKind.timeout
            ? (ar
                  ? 'تأخر الرد. قد تكون العملية تمت؛ تحقق من قائمة المرافقين قبل إعادة الإرسال.'
                  : 'Response timed out. Check the caregiver list before submitting again; the operation may have completed.')
            : failure.message(AppLocalizations.of(context));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    if (!widget.isCurrent()) return const SizedBox.shrink();
    final editing = widget.member != null;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(
          _generated != null
              ? (ar ? 'بيانات دخول المرافق' : 'Caregiver credentials')
              : editing
              ? (ar ? 'تعديل المرافق' : 'Edit caregiver')
              : (ar ? 'إضافة مرافق' : 'Add caregiver'),
        ),
        content: SizedBox(
          width: 420,
          child: _generated != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      '${_controllers['username']!.text}\n$_generated',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      ar
                          ? 'تظهر كلمة المرور المُنشأة الآن فقط. سلّمها للمرافق بطريقة آمنة.'
                          : 'The generated password is shown now only. Share it securely with the caregiver.',
                    ),
                  ],
                )
              : Form(
                  key: _form,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (editing)
                        Text(
                          ar
                              ? 'الاسم والهاتف بيانات لهذا الحساب؛ قد يظهر التعديل للمرضى الآخرين المرتبطين به.'
                              : 'Name and phone belong to this account; edits may be visible to other linked patients.',
                        ),
                      if (_error != null)
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      for (final field in [
                        'name',
                        if (!editing) 'username',
                        'phone',
                        'relation',
                        if (!editing) 'password',
                      ]) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _controllers[field],
                          readOnly: _busy,
                          obscureText: field == 'password',
                          autocorrect: false,
                          enableSuggestions: field != 'password',
                          maxLength: switch (field) {
                            'name' => 120,
                            'phone' => 32,
                            'password' => 128,
                            _ => 64,
                          },
                          decoration: InputDecoration(
                            labelText: switch (field) {
                              'name' => ar ? 'الاسم *' : 'Name *',
                              'username' =>
                                ar ? 'اسم المستخدم *' : 'Username *',
                              'phone' =>
                                ar ? 'الهاتف (اختياري)' : 'Phone (optional)',
                              'relation' =>
                                ar
                                    ? 'صلة القرابة (اختيارية)'
                                    : 'Relationship (optional)',
                              _ =>
                                ar
                                    ? 'كلمة المرور (اختيارية)'
                                    : 'Password (optional)',
                            },
                            helperText: field == 'password'
                                ? (ar
                                      ? '6 أحرف على الأقل؛ اتركها فارغة للتوليد الآمن.'
                                      : 'At least 6 characters; leave empty to generate securely.')
                                : null,
                            helperMaxLines: 2,
                          ),
                          validator: (value) {
                            if (field == 'name' &&
                                (value?.trim().isEmpty ?? true)) {
                              return ar ? 'أدخل الاسم' : 'Enter a name';
                            }
                            if (field == 'username' &&
                                (value?.trim().length ?? 0) < 3) {
                              return ar
                                  ? 'استخدم 3 أحرف على الأقل'
                                  : 'Use at least 3 characters';
                            }
                            if (field == 'password' &&
                                value != null &&
                                value.isNotEmpty &&
                                value.length < 6) {
                              return ar
                                  ? 'استخدم 6 أحرف على الأقل'
                                  : 'Use at least 6 characters';
                            }
                            return null;
                          },
                        ),
                      ],
                      if (_busy) const LinearProgressIndicator(),
                    ],
                  ),
                ),
        ),
        actions: _generated != null
            ? [FilledButton(onPressed: _close, child: Text(ar ? 'تم' : 'Done'))]
            : [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context, false),
                  child: Text(ar ? 'إلغاء' : 'Cancel'),
                ),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(ar ? 'حفظ' : 'Save'),
                ),
              ],
      ),
    );
  }
}
