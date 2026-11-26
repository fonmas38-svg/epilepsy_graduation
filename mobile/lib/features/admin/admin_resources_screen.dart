import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/errors/failure.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';

/// Native clients of the existing administrator account/device APIs.
class AdminResourcesScreen extends StatefulWidget {
  const AdminResourcesScreen({super.key, this.devices = false});
  final bool devices;
  @override
  State<AdminResourcesScreen> createState() => _AdminResourcesScreenState();
}

class _AdminResourcesScreenState extends State<AdminResourcesScreen> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _patients = [];
  bool _loading = true;
  bool _busy = false;
  Failure? _failure;
  bool get ar => AppLocalizations.of(context).isArabic;
  String get base => widget.devices ? '/admin/devices' : '/admin/users';
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final owner = app.auth.currentUser?.uid;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final body = await app.api.getObject(base);
      final users = widget.devices
          ? await app.api.getAdminUsers(role: 'patient')
          : <Map<String, dynamic>>[];
      if (!mounted || app.auth.currentUser?.uid != owner) return;
      setState(() {
        _items = (body[widget.devices ? 'devices' : 'users'] as List? ?? [])
            .whereType<Map>()
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
        _patients = users;
      });
    } catch (error) {
      if (mounted) setState(() => _failure = Failure.from(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _write(
    String method,
    String path,
    Map<String, Object?> body,
  ) async {
    if (_busy) return;
    final app = context.read<AppState>();
    final owner = app.auth.currentUser?.uid;
    setState(() => _busy = true);
    try {
      final result = await app.api.sendJson(
        method: method,
        path: path,
        body: body,
      );
      if (!mounted || app.auth.currentUser?.uid != owner) return;
      final secret =
          result['generatedEnrollmentSecret'] ?? result['generatedPassword'];
      if (secret is String && secret.isNotEmpty) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialog) => AlertDialog(
            title: Text(ar ? 'احفظ الاعتماد الآن' : 'Save this credential now'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ar
                        ? 'يظهر مرة واحدة في هذه الاستجابة. سلّمه للمخول عبر وسيلة آمنة. لا تشاركه في سجل عام.'
                        : 'Shown once in this response. Deliver it securely to the authorized recipient. Do not place it in public logs.',
                  ),
                  const SizedBox(height: 16),
                  SelectableText(secret, textDirection: TextDirection.ltr),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(ar ? 'تم' : 'Done'),
              ),
            ],
          ),
        );
      } else {
        AppSnack.success(context, ar ? 'حُفظ التغيير' : 'Change saved');
      }
      if (mounted) await _load();
    } catch (error) {
      if (mounted) {
        AppSnack.error(
          context,
          Failure.from(error).message(AppLocalizations.of(context)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(Map<String, dynamic> row, String action) async {
    if (_busy) return;
    final owner = context.read<AppState>().auth.currentUser?.uid;
    if (action == 'edit') {
      await _edit(row);
      return;
    }
    final id = row[widget.devices ? 'deviceId' : 'id'] as String;
    final title = switch (action) {
      'enable' => ar ? 'تمكين' : 'Enable',
      'disable' => ar ? 'تعطيل' : 'Disable',
      'delete' => ar ? 'حذف الحساب' : 'Delete account',
      _ =>
        widget.devices
            ? (ar ? 'تغيير سر الجهاز' : 'Rotate device secret')
            : (ar ? 'إعادة كلمة المرور' : 'Reset password'),
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('$title؟'),
        content: Text(
          '${row['name'] ?? id}\n\n${ar ? 'قد تفقد الجلسات أو الأجهزة المرتبطة صلاحية الاتصال. الحذف غير قابل للتراجع؛ لا يعني هذا مسح نسخة جهاز غير متصل.' : 'Associated sessions or devices may lose access. Deletion cannot be undone; this does not erase an offline device copy.'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(title),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        context.read<AppState>().auth.currentUser?.uid != owner) {
      return;
    }
    final encoded = Uri.encodeComponent(id);
    await _write(
      action == 'delete' ? 'DELETE' : 'POST',
      '$base/$encoded${action == 'delete' ? '' : '/$action'}',
      {},
    );
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    if (_busy) return;
    final owner = context.read<AppState>().auth.currentUser?.uid;
    final name = TextEditingController(text: row?['name'] as String? ?? '');
    final identifier = TextEditingController(
      text: row?[widget.devices ? 'deviceId' : 'username'] as String? ?? '',
    );
    final form = GlobalKey<FormState>();
    String role = 'patient';
    String? patient;
    final route = DialogRoute<Map<String, Object?>>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: Text(
            row == null
                ? (ar ? 'إضافة' : 'Add')
                : (ar ? 'تعديل الحساب' : 'Edit account'),
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: name,
                      maxLength: 120,
                      decoration: InputDecoration(
                        labelText: ar ? 'الاسم' : 'Name',
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? (ar ? 'مطلوب' : 'Required')
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: identifier,
                      maxLength: widget.devices ? 128 : 64,
                      decoration: InputDecoration(
                        labelText: widget.devices
                            ? (ar ? 'معرف الجهاز' : 'Device ID')
                            : (ar ? 'اسم المستخدم' : 'Username'),
                      ),
                      validator: (v) => v == null || v.trim().length < 3
                          ? (ar
                                ? 'ثلاثة أحرف على الأقل'
                                : 'At least 3 characters')
                          : null,
                    ),
                    if (!widget.devices && row == null)
                      DropdownButtonFormField<String>(
                        initialValue: role,
                        decoration: InputDecoration(
                          labelText: ar ? 'الدور' : 'Role',
                        ),
                        items: ['patient', 'caregiver', 'doctor', 'admin']
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(_role(value)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) => update(() => role = value!),
                      ),
                    if (widget.devices)
                      DropdownButtonFormField<String>(
                        initialValue: patient,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: ar ? 'المريض' : 'Patient',
                        ),
                        validator: (v) => v == null
                            ? (ar ? 'اختر المريض' : 'Choose a patient')
                            : null,
                        items: _patients
                            .where((p) => p['disabled'] != true)
                            .map(
                              (p) => DropdownMenuItem(
                                value: p['id'] as String,
                                child: Text(p['name'] as String? ?? ''),
                              ),
                            )
                            .toList(),
                        onChanged: (value) => update(() => patient = value),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      ar
                          ? 'الاعتماد الجديد يولّده الخادم ويظهر بعد النجاح. إنشاء الحساب لا يربطه تلقائيًا بكل المرضى.'
                          : 'The server generates a credential after success. Creating an account does not grant access to every patient.',
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(ar ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(dialog, <String, Object?>{
                    'name': name.text.trim(),
                    widget.devices ? 'device_id' : 'username': identifier.text
                        .trim(),
                    if (row == null && !widget.devices) 'role': role,
                    if (widget.devices) 'patient_id': patient,
                  });
                }
              },
              child: Text(ar ? 'حفظ' : 'Save'),
            ),
          ],
        ),
      ),
    );
    final result = await Navigator.of(context).push(route);
    await route.completed;
    name.dispose();
    identifier.dispose();
    if (result == null ||
        !mounted ||
        context.read<AppState>().auth.currentUser?.uid != owner) {
      return;
    }
    await _write(
      row == null ? 'POST' : 'PATCH',
      row == null ? base : '$base/${Uri.encodeComponent(row['id'] as String)}',
      result,
    );
  }

  String _role(String value) => ar
      ? switch (value) {
          'patient' => 'مريض',
          'doctor' => 'طبيب',
          'caregiver' => 'مرافق',
          'admin' => 'مشرف',
          _ => value,
        }
      : switch (value) {
          'patient' => 'Patient',
          'doctor' => 'Doctor',
          'caregiver' => 'Caregiver',
          'admin' => 'Administrator',
          _ => value,
        };
  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final rows = _items
        .where(
          (r) => '${r['name']} ${r['username'] ?? r['deviceId']}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.devices
              ? (ar ? 'الأجهزة' : 'Devices')
              : (ar ? 'الحسابات' : 'Accounts'),
        ),
        actions: [
          IconButton(
            tooltip: ar ? 'تحديث' : 'Refresh',
            onPressed: _loading || _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ResponsiveContent(
        maxWidth: 1040,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: ar ? 'بحث' : 'Search',
                      prefixIcon: const Icon(Icons.search),
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _loading || _busy || _failure != null
                      ? null
                      : () => _edit(),
                  icon: const Icon(Icons.add),
                  label: Text(
                    widget.devices
                        ? (ar ? 'إضافة جهاز' : 'Add device')
                        : (ar ? 'إنشاء حساب' : 'Create account'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_loading || _busy) const LinearProgressIndicator(),
            if (_failure != null) ...[
              Text(_failure!.message(AppLocalizations.of(context))),
              TextButton(
                onPressed: _load,
                child: Text(ar ? 'إعادة المحاولة' : 'Retry'),
              ),
            ],
            if (!_loading && _failure == null && rows.isEmpty)
              EmptyState(title: ar ? 'لا توجد نتائج' : 'No results'),
            if (_failure == null)
              ...rows.map((row) {
                final own =
                    !widget.devices &&
                    row['id'] == context.read<AppState>().auth.currentUser?.uid;
                final enabled = row['disabled'] != true;
                return Card(
                  child: ListTile(
                    leading: Icon(
                      widget.devices
                          ? Icons.devices_outlined
                          : Icons.person_outline,
                    ),
                    title: Text(row['name'] as String? ?? ''),
                    subtitle: Text(
                      '${row[widget.devices ? 'deviceId' : 'username']} · ${widget.devices ? row['patientId'] : _role(row['role'] as String? ?? '')}\n${enabled ? (ar ? 'مفعّل' : 'Enabled') : (ar ? 'معطّل' : 'Disabled')}',
                    ),
                    trailing: PopupMenuButton<String>(
                      enabled: !_busy && !_loading,
                      onSelected: (action) => _action(row, action),
                      itemBuilder: (_) => [
                        if (!widget.devices)
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(ar ? 'تعديل' : 'Edit'),
                          ),
                        if (!own)
                          PopupMenuItem(
                            value: widget.devices ? 'secret' : 'password',
                            child: Text(
                              widget.devices
                                  ? (ar ? 'تغيير سر الجهاز' : 'Rotate secret')
                                  : (ar
                                        ? 'إعادة كلمة المرور'
                                        : 'Reset password'),
                            ),
                          ),
                        if (!own)
                          PopupMenuItem(
                            value: enabled ? 'disable' : 'enable',
                            child: Text(
                              enabled
                                  ? (ar ? 'تعطيل' : 'Disable')
                                  : (ar ? 'تمكين' : 'Enable'),
                            ),
                          ),
                        if (!widget.devices && !own)
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(ar ? 'حذف الحساب' : 'Delete account'),
                          ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
