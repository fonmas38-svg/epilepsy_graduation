import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/enums.dart';
import '../../core/errors/failure.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';

class AdminLinksScreen extends StatefulWidget {
  const AdminLinksScreen({super.key, this.initialDoctorId});
  final String? initialDoctorId;
  @override
  State<AdminLinksScreen> createState() => _AdminLinksScreenState();
}

class _AdminLinksScreenState extends State<AdminLinksScreen> {
  List<Map<String, dynamic>> _users = [], _doctors = [], _caregivers = [];
  String? _patient, _member;
  bool _family = false, _loading = true, _busy = false, _loaded = false;
  int _loadRevision = 0;
  String? _error;
  bool get ar => AppLocalizations.of(context).isArabic;
  String get path => _family ? '/admin/caregiver-links' : '/admin/assignments';
  String get memberKey => _family ? 'caregiverId' : 'doctorId';
  List<Map<String, dynamic>> get links => _family ? _caregivers : _doctors;
  List<Map<String, dynamic>> rows(Map<String, dynamic> body, String key) {
    if (body[key] is! List) {
      throw const FormatException('Invalid link response');
    }
    return (body[key] as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    final app = context.read<AppState>();
    final owner = app.auth.currentUser;
    final origin = app.api.baseUrl;
    final generation = ++_loadRevision;
    bool current() =>
        mounted &&
        generation == _loadRevision &&
        identical(app.auth.currentUser, owner) &&
        app.api.baseUrl == origin;
    setState(() {
      _loading = true;
      _loaded = false;
      _error = null;
    });
    try {
      if (owner?.role != UserRole.admin) {
        throw const Failure(FailureKind.forbidden);
      }
      final responses = await Future.wait([
        app.api.getObject('/admin/users'),
        app.api.getObject('/admin/assignments'),
        app.api.getObject('/admin/caregiver-links'),
      ]);
      final users = rows(responses[0], 'users');
      final doctors = rows(responses[1], 'assignments');
      final caregivers = rows(responses[2], 'links');
      if (!current()) return;
      setState(() {
        _users = users;
        _doctors = doctors;
        _caregivers = caregivers;
        _loaded = true;
        if (!_users.any(
          (u) =>
              u['id'] == _patient &&
              u['role'] == 'patient' &&
              u['disabled'] != true,
        )) {
          _patient = null;
        }
        _member ??= widget.initialDoctorId;
        if (!members.any((u) => u['id'] == _member)) _member = null;
      });
    } catch (error) {
      if (current()) {
        setState(
          () => _error = Failure.from(
            error,
          ).message(AppLocalizations.of(context)),
        );
      }
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get members => _users
      .where(
        (u) =>
            u['role'] == (_family ? 'caregiver' : 'doctor') &&
            u['disabled'] != true,
      )
      .toList();
  String name(String? id) {
    final matches = _users.where((u) => u['id'] == id);
    if (matches.isEmpty) return ar ? 'حساب غير متاح' : 'Unavailable account';
    final user = matches.first;
    return '${user['name'] ?? user['username'] ?? id}${user['disabled'] == true ? (ar ? ' (معطّل)' : ' (disabled)') : ''}';
  }

  Future<void> _change({Map<String, dynamic>? remove}) async {
    if (_busy || !_loaded || _loading) return;
    final patient = remove?['patientId'] as String? ?? _patient;
    final member = remove?[memberKey] as String? ?? _member;
    if (patient == null || member == null) return;
    final app = context.read<AppState>();
    final owner = app.auth.currentUser;
    final origin = app.api.baseUrl;
    final endpoint = path;
    final key = _family ? 'caregiver_id' : 'doctor_id';
    bool current() =>
        mounted &&
        identical(app.auth.currentUser, owner) &&
        app.api.baseUrl == origin;
    final title = remove == null
        ? (ar ? 'تأكيد الربط' : 'Confirm link')
        : (ar ? 'إلغاء الربط' : 'Remove link');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(
          '${name(patient)} ↔ ${name(member)}\n${remove == null ? (ar ? 'سيتم منح الوصول وفق صلاحيات هذا الحساب.' : 'Access will follow this account’s permissions.') : (ar ? 'سيُزال هذا الرابط فقط؛ لن يُحذف الحساب أو سجل المريض. لا يمكن سحب بيانات سبق تسليمها.' : 'Only this link is removed. Accounts and patient records remain; previously delivered data cannot be recalled.')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ar ? 'رجوع' : 'Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(title),
          ),
        ],
      ),
    );
    if (accepted != true ||
        !current() ||
        owner?.role != UserRole.admin ||
        _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    var success = false;
    try {
      await app.api.sendJson(
        method: remove == null ? 'POST' : 'DELETE',
        path: endpoint,
        body: {'patient_id': patient, key: member},
      );
      if (!current()) return;
      success = true;
    } catch (error) {
      if (current()) {
        setState(() {
          _loaded = false;
          final failure = Failure.from(error);
          _error = failure.kind == FailureKind.timeout
              ? (ar
                    ? 'تأخر الرد. حدّث الروابط للتحقق من النتيجة قبل تكرار العملية.'
                    : 'Response timed out. Refresh links to verify the result before repeating the operation.')
              : failure.message(AppLocalizations.of(context));
        });
      }
    } finally {
      if (current()) setState(() => _busy = false);
    }
    if (success && current()) {
      await _load();
      if (!mounted) return;
      if (current()) {
        AppSnack.success(context, ar ? 'تم تحديث الرابط' : 'Link updated');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedLinks = links
        .where((r) => _patient == null || r['patientId'] == _patient)
        .toList();
    final existing = links.any(
      (r) => r['patientId'] == _patient && r[memberKey] == _member,
    );
    final enabled = !_busy && !_loading && _loaded;
    return Scaffold(
      appBar: AppBar(
        title: Text(ar ? 'روابط الرعاية' : 'Care links'),
        actions: [
          IconButton(
            tooltip: ar ? 'تحديث الروابط' : 'Refresh links',
            onPressed: _busy || _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ResponsiveContent(
        maxWidth: 900,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: Text(ar ? 'الأطباء' : 'Doctors'),
                  selected: !_family,
                  onSelected: enabled
                      ? (_) => setState(() {
                          _family = false;
                          _member = null;
                        })
                      : null,
                ),
                ChoiceChip(
                  label: Text(ar ? 'المرافقون' : 'Caregivers'),
                  selected: _family,
                  onSelected: enabled
                      ? (_) => setState(() {
                          _family = true;
                          _member = null;
                        })
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_loading || _busy) const LinearProgressIndicator(),
            if (_error != null)
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
            if (!_loading && !_loaded)
              TextButton(
                onPressed: _busy ? null : _load,
                child: Text(ar ? 'إعادة تحميل الروابط' : 'Reload links'),
              ),
            if (_loaded) ...[
              DropdownButtonFormField<String>(
                key: ValueKey(('patient', _patient)),
                initialValue: _patient,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: ar ? 'المريض' : 'Patient',
                ),
                items: [
                  DropdownMenuItem<String>(
                    value: null,
                    child: Text(
                      ar
                          ? 'كل المرضى — اختر للربط'
                          : 'All patients — select to link',
                    ),
                  ),
                  ..._users
                      .where(
                        (u) => u['role'] == 'patient' && u['disabled'] != true,
                      )
                      .map(
                        (u) => DropdownMenuItem(
                          value: u['id'] as String,
                          child: Text(name(u['id'] as String)),
                        ),
                      ),
                ],
                onChanged: enabled
                    ? (value) => setState(() => _patient = value)
                    : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey((_family, _member)),
                initialValue: _member,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: _family
                      ? (ar ? 'المرافق' : 'Caregiver')
                      : (ar ? 'الطبيب' : 'Doctor'),
                ),
                items: members
                    .map(
                      (u) => DropdownMenuItem(
                        value: u['id'] as String,
                        child: Text(name(u['id'] as String)),
                      ),
                    )
                    .toList(),
                onChanged: enabled
                    ? (value) => setState(() => _member = value)
                    : null,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed:
                    enabled && _patient != null && _member != null && !existing
                    ? () => _change()
                    : null,
                icon: const Icon(Icons.link),
                label: Text(
                  existing
                      ? (ar ? 'الرابط موجود بالفعل' : 'Already linked')
                      : (ar ? 'إضافة رابط' : 'Add link'),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                ar ? 'الروابط الحالية' : 'Current links',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (selectedLinks.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(ar ? 'لا توجد روابط' : 'No links'),
                ),
              ...selectedLinks.map(
                (row) => Card(
                  child: ListTile(
                    title: Text(name(row['patientId'] as String?)),
                    subtitle: Text(
                      '${name(row[memberKey] as String?)}${row['disabled'] == true ? (ar ? ' — رابط معطّل' : ' — link disabled') : ''}',
                    ),
                    trailing: IconButton(
                      tooltip: ar ? 'إلغاء الربط' : 'Remove link',
                      onPressed: enabled ? () => _change(remove: row) : null,
                      icon: const Icon(Icons.link_off),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
