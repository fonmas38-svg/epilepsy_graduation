import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors/failure.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import 'admin_security_guard.dart';
import 'admin_user_detail_sheet.dart';
import 'create_doctor_dialog.dart';

/// Native clients of the administrator account and device management APIs.
class AdminResourcesScreen extends StatefulWidget {
  const AdminResourcesScreen({super.key, this.devices = false});
  final bool devices;
  @override
  State<AdminResourcesScreen> createState() => _AdminResourcesScreenState();
}

class _AdminResourcesScreenState extends State<AdminResourcesScreen> {
  final _search = TextEditingController();
  final _uuid = const Uuid();
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _patients = [];
  Map<String, String> _patientNames = {};
  String _roleFilter = '';
  String _statusFilter = '';
  String _enrollmentFilter = '';
  String? _patientFilter;
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
      final names = <String, String>{};
      for (final p in users) {
        final id = p['id']?.toString() ?? '';
        if (id.isNotEmpty) {
          names[id] = p['name']?.toString() ?? p['username']?.toString() ?? id;
        }
      }
      setState(() {
        _items = (body[widget.devices ? 'devices' : 'users'] as List? ?? [])
            .whereType<Map>()
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
        _patients = users;
        _patientNames = names;
      });
    } catch (error) {
      if (mounted) setState(() => _failure = Failure.from(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showSecretDialog(String secret) async {
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
        await _showSecretDialog(secret);
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

  Future<void> _openDetails(String userId) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AdminUserDetailSheet(userId: userId),
    );
    if (mounted) await _load();
  }

  Future<void> _revokeSessions(Map<String, dynamic> row) async {
    final id = row['id']?.toString() ?? '';
    final name = row['name']?.toString() ?? row['username']?.toString() ?? id;
    final verified = await requireAdminVerification(
      context,
      ar
          ? 'فك قفل الأجهزة وإنهاء جلسات الحساب $name'
          : 'Unlock devices and end sessions for $name',
    );
    if (!verified || !mounted) return;
    setState(() => _busy = true);
    try {
      final revoked = await context
          .read<AppState>()
          .api
          .adminRevokeUserSessions(id);
      if (!mounted) return;
      AppSnack.success(
        context,
        ar
            ? 'تم إنهاء $revoked جلسة وفك ربط الجهاز'
            : 'Ended $revoked sessions and unlocked device',
      );
      await _load();
    } catch (e) {
      if (mounted) {
        AppSnack.error(
          context,
          Failure.from(e).message(AppLocalizations.of(context)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openCreateDoctorDialog() async {
    final verified = await requireAdminVerification(
      context,
      ar ? 'إضافة طبيب معالج جديد' : 'Add a new treating doctor',
    );
    if (!verified || !mounted) return;

    final app = context.read<AppState>();
    final owner = app.auth.currentUser;
    final origin = app.api.baseUrl;
    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CreateDoctorDialog(
        verifyMoh: ({required licenseNumber, nationalId, name}) async {
          if (!AppUser.sameSessionOwner(app.auth.currentUser, owner) ||
              app.api.baseUrl != origin) {
            throw const Failure(FailureKind.unauthorized);
          }
          return app.api.verifyAdminDoctorMoh(
            licenseNumber: licenseNumber,
            nationalId: nationalId,
            name: name,
          );
        },
        createExtended:
            ({
              required name,
              required username,
              required password,
              phone,
              email,
              licenseNumber,
              specialization,
              hospitalAffiliation,
              nationalId,
              mohOverride = false,
              required idempotencyKey,
            }) async {
              await app.api.createAdminDoctor(
                name: name,
                username: username,
                password: password,
                phone: phone,
                email: email,
                licenseNumber: licenseNumber,
                specialization: specialization,
                hospitalAffiliation: hospitalAffiliation,
                nationalId: nationalId,
                mohOverride: mohOverride,
                idempotencyKey: idempotencyKey,
              );
            },
        create:
            ({
              required name,
              required username,
              required password,
              phone,
            }) async {
              await app.api.createAdminDoctor(
                name: name,
                username: username,
                password: password,
                phone: phone,
              );
            },
      ),
    );
    if (created == true && mounted) {
      AppSnack.success(context, ar ? 'تم تسجيل الطبيب' : 'Doctor registered');
      await _load();
    }
  }

  Future<void> _action(Map<String, dynamic> row, String action) async {
    if (_busy) return;
    final owner = context.read<AppState>().auth.currentUser?.uid;
    if (action == 'details') {
      await _openDetails(row['id'] as String);
      return;
    }
    if (action == 'revoke_sessions') {
      await _revokeSessions(row);
      return;
    }
    if (action == 'edit') {
      await _edit(row);
      return;
    }
    final id = row[widget.devices ? 'deviceId' : 'id'] as String;
    final title = switch (action) {
      'enable' => ar ? 'تمكين' : 'Enable',
      'disable' => ar ? 'تعطيل' : 'Disable',
      'delete' =>
        widget.devices
            ? (ar ? 'حذف الجهاز' : 'Delete device')
            : (ar ? 'حذف الحساب' : 'Delete account'),
      _ =>
        widget.devices
            ? (ar ? 'تغيير سر الجهاز' : 'Rotate device secret')
            : (ar ? 'إعادة كلمة المرور' : 'Reset password'),
    };
    final verified = await requireAdminVerification(
      context,
      '$title: ${row['name'] ?? id}',
    );
    if (!verified ||
        !mounted ||
        context.read<AppState>().auth.currentUser?.uid != owner) {
      return;
    }
    final encoded = Uri.encodeComponent(id);
    if (widget.devices && action == 'delete') {
      setState(() => _busy = true);
      try {
        await context.read<AppState>().api.deleteAdminDevice(id);
        if (!mounted) return;
        AppSnack.success(context, ar ? 'تم حذف الجهاز' : 'Device deleted');
        await _load();
      } catch (e) {
        if (mounted) {
          AppSnack.error(
            context,
            Failure.from(e).message(AppLocalizations.of(context)),
          );
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
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
    final email = TextEditingController(text: row?['email'] as String? ?? '');
    final phone = TextEditingController();
    final age = TextEditingController();
    final emergencyContact = TextEditingController();
    final diagnosis = TextEditingController();
    final form = GlobalKey<FormState>();
    String role = row == null && !widget.devices
        ? 'patient'
        : (row?['role'] as String? ?? 'patient');
    String gender = 'male';
    String? patient = row?['patientId'] as String?;

    final route = DialogRoute<Map<String, Object?>>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: Text(
            row == null
                ? (widget.devices
                      ? (ar ? 'إضافة جهاز' : 'Add device')
                      : (ar ? 'إنشاء حساب' : 'Create account'))
                : (widget.devices
                      ? (ar ? 'تعديل الجهاز' : 'Edit device')
                      : (ar ? 'تعديل الحساب' : 'Edit account')),
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!widget.devices && row == null) ...[
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
                        onChanged: (value) {
                          if (value == 'doctor') {
                            Navigator.pop(dialog, {'_openDoctorDialog': true});
                            return;
                          }
                          update(() => role = value!);
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
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
                      enabled: !(widget.devices && row != null),
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
                    if (!widget.devices) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: ar
                              ? 'البريد الإلكتروني (اختياري)'
                              : 'Email (optional)',
                        ),
                      ),
                    ],
                    if (!widget.devices &&
                        row == null &&
                        role == 'patient') ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: phone,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: ar ? 'رقم الهاتف' : 'Phone',
                        ),
                        validator: (v) => v == null || v.trim().length < 8
                            ? (ar
                                  ? 'رقم هاتف صالح مطلوب'
                                  : 'Valid phone required')
                            : null,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: age,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: ar ? 'العمر' : 'Age',
                              ),
                              validator: (v) {
                                final parsed = int.tryParse((v ?? '').trim());
                                if (parsed == null ||
                                    parsed < 0 ||
                                    parsed > 130) {
                                  return ar ? '0–130' : '0–130';
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: gender,
                              decoration: InputDecoration(
                                labelText: ar ? 'الجنس' : 'Gender',
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 'male',
                                  child: Text(ar ? 'ذكر' : 'Male'),
                                ),
                                DropdownMenuItem(
                                  value: 'female',
                                  child: Text(ar ? 'أنثى' : 'Female'),
                                ),
                              ],
                              onChanged: (v) =>
                                  update(() => gender = v ?? 'male'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: emergencyContact,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: ar ? 'هاتف الطوارئ' : 'Emergency contact',
                        ),
                        validator: (v) => v == null || v.trim().length < 8
                            ? (ar
                                  ? 'رقم طوارئ صالح مطلوب'
                                  : 'Valid emergency contact required')
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: diagnosis,
                        decoration: InputDecoration(
                          labelText: ar ? 'التشخيص الطبي' : 'Diagnosis',
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? (ar ? 'التشخيص مطلوب' : 'Diagnosis required')
                            : null,
                      ),
                    ],
                    if (widget.devices)
                      DropdownButtonFormField<String>(
                        initialValue:
                            _patients.any(
                              (p) =>
                                  p['id'] == patient && p['disabled'] != true,
                            )
                            ? patient
                            : null,
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
                          ? 'الاعتماد الجديد يولّده الخادم ويظهر بعد النجاح. إنشاء الحساب لا يربطه تلقائياً بكل المرضى.'
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
                    if (!widget.devices && email.text.trim().isNotEmpty)
                      'email': email.text.trim(),
                    if (row == null && !widget.devices) 'role': role,
                    if (row == null &&
                        !widget.devices &&
                        role == 'patient') ...{
                      'phone': phone.text.trim(),
                      'age': int.parse(age.text.trim()),
                      'gender': gender,
                      'emergency_contact': emergencyContact.text.trim(),
                      'diagnosis': diagnosis.text.trim(),
                    },
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
    email.dispose();
    phone.dispose();
    age.dispose();
    emergencyContact.dispose();
    diagnosis.dispose();

    if (result == null ||
        !mounted ||
        context.read<AppState>().auth.currentUser?.uid != owner) {
      return;
    }
    if (result['_openDoctorDialog'] == true) {
      await _openCreateDoctorDialog();
      return;
    }

    final verified = await requireAdminVerification(
      context,
      row == null
          ? (widget.devices
                ? (ar ? 'إضافة جهاز جديد' : 'Add new device')
                : (ar ? 'إنشاء حساب جديد' : 'Create new account'))
          : (widget.devices
                ? (ar ? 'تعديل بيانات الجهاز' : 'Update device')
                : (ar ? 'تعديل بيانات الحساب' : 'Update account')),
    );
    if (!verified || !mounted) return;

    if (widget.devices && row != null) {
      setState(() => _busy = true);
      try {
        await context.read<AppState>().api.updateAdminDevice(
          row['deviceId'] as String,
          name: result['name'] as String?,
          patientId: result['patient_id'] as String?,
        );
        if (!mounted) return;
        AppSnack.success(context, ar ? 'تم تحديث الجهاز' : 'Device updated');
        await _load();
      } catch (e) {
        if (mounted) {
          AppSnack.error(
            context,
            Failure.from(e).message(AppLocalizations.of(context)),
          );
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    if (!widget.devices && row == null && result['role'] == 'patient') {
      setState(() => _busy = true);
      try {
        final created = await context.read<AppState>().api.createAdminPatient(
          username: result['username'] as String,
          name: result['name'] as String,
          email: result['email'] as String?,
          phone: result['phone'] as String,
          age: result['age'] as int,
          gender: result['gender'] as String,
          emergencyContact: result['emergency_contact'] as String,
          diagnosis: result['diagnosis'] as String,
          idempotencyKey: _uuid.v4(),
        );
        if (!mounted) return;
        final pw = created['generatedPassword'] as String?;
        if (pw != null && pw.isNotEmpty) {
          await _showSecretDialog(pw);
        } else {
          AppSnack.success(
            context,
            ar ? 'تم إنشاء حساب المريض' : 'Patient created',
          );
        }
        await _load();
      } catch (e) {
        if (mounted) {
          AppSnack.error(
            context,
            Failure.from(e).message(AppLocalizations.of(context)),
          );
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
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

  List<Map<String, dynamic>> _filteredRows() {
    final query = _search.text.trim().toLowerCase();
    return _items.where((r) {
      final isDisabled = r['disabled'] == true;
      if (_statusFilter == 'enabled' && isDisabled) return false;
      if (_statusFilter == 'disabled' && !isDisabled) return false;

      if (widget.devices) {
        final pid = r['patientId']?.toString() ?? '';
        final enrolled =
            r['lastEnrolledAt'] != null && '${r['lastEnrolledAt']}'.isNotEmpty;
        if (_enrollmentFilter == 'enrolled' && !enrolled) return false;
        if (_enrollmentFilter == 'unregistered' && enrolled) return false;
        if (_patientFilter != null &&
            _patientFilter!.isNotEmpty &&
            pid != _patientFilter) {
          return false;
        }
        if (query.isEmpty) return true;
        final patientName = _patientNames[pid] ?? '';
        final searchable = [
          r['name'],
          r['deviceId'],
          pid,
          patientName,
        ].whereType<Object>().map((v) => v.toString().toLowerCase()).join(' ');
        return searchable.contains(query);
      } else {
        final role = r['role']?.toString() ?? '';
        if (_roleFilter.isNotEmpty && role != _roleFilter) return false;
        if (query.isEmpty) return true;
        final meta = r['meta'] as Map? ?? {};
        final searchable = [
          r['name'],
          r['username'],
          r['email'],
          r['id'],
          meta['phone'],
          meta['licenseNumber'],
        ].whereType<Object>().map((v) => v.toString().toLowerCase()).join(' ');
        return searchable.contains(query);
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filteredRows();
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
                  width: 280,
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: widget.devices
                          ? (ar
                                ? 'بحث بالاسم أو المعرف أو المريض'
                                : 'Search name, ID or patient')
                          : (ar
                                ? 'بحث بالاسم أو المستخدم أو الهاتف'
                                : 'Search name, username, phone'),
                      prefixIcon: const Icon(Icons.search),
                    ),
                  ),
                ),
                if (widget.devices)
                  SizedBox(
                    width: 220,
                    child: DropdownButtonFormField<String?>(
                      initialValue: _patientFilter,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: ar
                            ? 'تصفية حسب المريض'
                            : 'Filter by patient',
                      ),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(ar ? 'كل المرضى' : 'All patients'),
                        ),
                        ..._patients.map(
                          (p) => DropdownMenuItem<String?>(
                            value: p['id'] as String?,
                            child: Text(p['name'] as String? ?? ''),
                          ),
                        ),
                      ],
                      onChanged: (v) => setState(() => _patientFilter = v),
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
            const SizedBox(height: 12),
            if (!widget.devices)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final entry in [
                    ('', ar ? 'كل الأدوار' : 'All roles'),
                    ('patient', ar ? 'المرضى' : 'Patients'),
                    ('doctor', ar ? 'الأطباء' : 'Doctors'),
                    ('caregiver', ar ? 'المرافقون' : 'Caregivers'),
                    ('admin', ar ? 'المشرفون' : 'Admins'),
                  ])
                    FilterChip(
                      label: Text(entry.$2),
                      selected: _roleFilter == entry.$1,
                      onSelected: (_) => setState(() => _roleFilter = entry.$1),
                    ),
                ],
              ),
            if (widget.devices)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final entry in [
                    ('', ar ? 'كل الارتباطات' : 'All enrollments'),
                    ('enrolled', ar ? 'مسجل ومتصل' : 'Enrolled'),
                    ('unregistered', ar ? 'لم يتصل بعد' : 'Not enrolled'),
                  ])
                    FilterChip(
                      label: Text(entry.$2),
                      selected: _enrollmentFilter == entry.$1,
                      onSelected: (_) =>
                          setState(() => _enrollmentFilter = entry.$1),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final entry in [
                  ('', ar ? 'كل الحالات' : 'All states'),
                  ('enabled', ar ? 'مفعّل' : 'Enabled'),
                  ('disabled', ar ? 'معطّل' : 'Disabled'),
                ])
                  ChoiceChip(
                    label: Text(entry.$2),
                    selected: _statusFilter == entry.$1,
                    onSelected: (_) => setState(() => _statusFilter = entry.$1),
                  ),
              ],
            ),
            const SizedBox(height: 16),
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
                final pid = row['patientId']?.toString() ?? '';
                final patientDisplay = _patientNames[pid] ?? pid;
                final lastEnrolled = DateTime.tryParse(
                  '${row['lastEnrolledAt'] ?? ''}',
                );
                return Card(
                  child: ListTile(
                    onTap: widget.devices
                        ? null
                        : () => _openDetails(row['id'] as String),
                    leading: CircleAvatar(
                      backgroundColor: enabled
                          ? AppColors.accent(context, AccentTone.blue).container
                          : AppColors.of(context, RiskView.danger).container,
                      child: Icon(
                        widget.devices
                            ? Icons.devices_outlined
                            : Icons.person_outline,
                        color: enabled
                            ? Theme.of(context).colorScheme.primary
                            : AppColors.of(context, RiskView.danger).foreground,
                      ),
                    ),
                    title: Text(row['name'] as String? ?? ''),
                    subtitle: Text(
                      widget.devices
                          ? '${row['deviceId']} · ${ar ? 'المريض' : 'Patient'}: $patientDisplay\n'
                                '${enabled ? (ar ? 'مفعّل' : 'Enabled') : (ar ? 'معطّل' : 'Disabled')} · '
                                '${lastEnrolled == null ? (ar ? 'لم يتصل بعد' : 'Not enrolled yet') : '${ar ? 'آخر اتصال' : 'Last enrolled'}: ${TimeAgo.stamp(lastEnrolled)}'}'
                          : '${row['username']} · ${_role(row['role'] as String? ?? '')}\n'
                                '${enabled ? (ar ? 'مفعّل' : 'Enabled') : (ar ? 'معطّل' : 'Disabled')}'
                                '${'${row['email'] ?? ''}'.isEmpty ? '' : ' · ${row['email']}'}',
                    ),
                    trailing: PopupMenuButton<String>(
                      enabled: !_busy && !_loading,
                      onSelected: (action) => _action(row, action),
                      itemBuilder: (_) => [
                        if (!widget.devices)
                          PopupMenuItem(
                            value: 'details',
                            child: Text(ar ? 'عرض التفاصيل' : 'View details'),
                          ),
                        PopupMenuItem(
                          value: 'edit',
                          child: Text(
                            widget.devices
                                ? (ar ? 'تعديل / نقل لمريض' : 'Edit / Reassign')
                                : (ar ? 'تعديل' : 'Edit'),
                          ),
                        ),
                        if (!widget.devices && !own)
                          PopupMenuItem(
                            value: 'revoke_sessions',
                            child: Text(
                              ar ? 'فك ربط الأجهزة' : 'Revoke sessions',
                            ),
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
                        if (!own)
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(
                              widget.devices
                                  ? (ar ? 'حذف الجهاز' : 'Delete device')
                                  : (ar ? 'حذف الحساب' : 'Delete account'),
                            ),
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
