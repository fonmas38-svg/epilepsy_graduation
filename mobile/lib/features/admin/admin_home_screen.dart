import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/enums.dart';
import '../../core/errors/failure.dart';
import '../../core/router/route_names.dart';
import '../../core/ui/common.dart';
import '../../core/ui/session_actions.dart';
import '../../core/ui/workspace_scaffold.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import 'create_doctor_dialog.dart';

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});
  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  Map<String, dynamic>? _counts;
  List<Map<String, dynamic>>? _users, _audit;
  final _loading = <String>{};
  final _errors = <String, Failure>{};
  final _revisions = <String, int>{};
  final _filter = TextEditingController();
  Object? _owner;
  String? _origin;
  int _auditLimit = 20;
  bool _launching = false;
  bool get ar => AppLocalizations.of(context).isArabic;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _owner = app.auth.currentUser;
    _origin = app.api.baseUrl;
    _loadAdminData();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  bool _current() {
    final app = context.read<AppState>();
    return mounted &&
        identical(app.auth.currentUser, _owner) &&
        app.api.baseUrl == _origin &&
        app.auth.currentUser?.role == UserRole.admin;
  }

  List<Map<String, dynamic>> _rows(Map<String, dynamic> body, String key) {
    final raw = body[key];
    if (raw is! List) throw const FormatException('Missing resource list');
    return raw.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  Future<void> _loadAdminData() async {
    await Future.wait(['overview', 'users', 'audit'].map(_load));
  }

  Future<void> _load(String section) async {
    if (!_current() || _loading.contains(section)) return;
    final app = context.read<AppState>();
    final revision = (_revisions[section] ?? 0) + 1;
    _revisions[section] = revision;
    setState(() {
      _loading.add(section);
      _errors.remove(section);
    });
    try {
      final path = switch (section) {
        'overview' => '/admin/overview',
        'users' => '/admin/users',
        _ => '/admin/audit?limit=$_auditLimit',
      };
      final body = await app.api.getObject(path);
      Map<String, dynamic>? counts;
      List<Map<String, dynamic>>? rows;
      if (section == 'overview') {
        final raw = body['counts'];
        if (raw is! Map ||
            raw['byRole'] is! Map ||
            [
              'doctor',
              'patient',
              'caregiver',
              'admin',
            ].any((role) => raw['byRole'][role] is! num)) {
          throw const FormatException('Invalid overview counts');
        }
        counts = Map<String, dynamic>.from(raw);
      } else {
        rows = _rows(body, section == 'users' ? 'users' : 'audit');
      }
      if (!_current() || _revisions[section] != revision) return;
      setState(() {
        if (section == 'overview') _counts = counts;
        if (section == 'users') _users = rows;
        if (section == 'audit') _audit = rows;
      });
    } catch (error) {
      if (_current() && _revisions[section] == revision) {
        setState(() {
          _errors[section] = Failure.from(error);
          if (section == 'overview') _counts = null;
          if (section == 'users') _users = null;
          if (section == 'audit') _audit = null;
        });
      }
    } finally {
      if (_current() && _revisions[section] == revision) {
        setState(() => _loading.remove(section));
      }
    }
  }

  Future<void> _launchPortal() async {
    if (_launching || !_current()) return;
    setState(() => _launching = true);
    try {
      final uri = Uri.parse('${_origin!}/admin');
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (mounted && _current() && !opened) {
        AppSnack.error(
          context,
          ar ? 'تعذر فتح البوابة' : 'Could not open portal',
        );
      }
    } catch (error) {
      if (mounted && _current()) {
        AppSnack.error(
          context,
          ar ? 'تعذر فتح البوابة' : 'Could not open portal',
        );
      }
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  // Confirmation is not password reauthentication; the API enforces admin access.
  Future<bool> _requireAdminSecurityVerification(String actionTitle) async {
    final app = context.read<AppState>();
    final owner = app.auth.currentUser;
    final origin = app.api.baseUrl;
    if (owner?.role != UserRole.admin) return false;
    if (await app.biometrics.isAvailable && await app.biometrics.isEnabled()) {
      final accepted = await app.biometrics.authenticate(
        localizedReason: actionTitle,
      );
      return mounted &&
          accepted &&
          identical(app.auth.currentUser, owner) &&
          app.api.baseUrl == origin;
    }
    if (!mounted ||
        !identical(app.auth.currentUser, owner) ||
        app.api.baseUrl != origin) {
      return false;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد العملية'),
        content: Text(
          '$actionTitle\nسيتحقق الخادم من صلاحية حساب المشرف عند التنفيذ.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
    return mounted &&
        confirmed == true &&
        identical(app.auth.currentUser, owner) &&
        app.api.baseUrl == origin;
  }

  Future<void> _openAddDoctorDialog() async {
    final verified = await _requireAdminSecurityVerification(
      'إضافة طبيب معالج جديد',
    );
    if (!verified || !mounted) return;

    final app = context.read<AppState>();
    final owner = app.auth.currentUser;
    final origin = app.api.baseUrl;
    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CreateDoctorDialog(
        create:
            ({
              required name,
              required username,
              required password,
              phone,
            }) async {
              if (!identical(app.auth.currentUser, owner) ||
                  app.api.baseUrl != origin) {
                throw const Failure(FailureKind.unauthorized);
              }
              await app.api.createAdminDoctor(
                name: name,
                username: username,
                password: password,
                phone: phone,
              );
              if (!identical(app.auth.currentUser, owner) ||
                  app.api.baseUrl != origin) {
                throw const Failure(FailureKind.unauthorized);
              }
            },
      ),
    );
    if (!mounted ||
        created != true ||
        !identical(app.auth.currentUser, owner) ||
        app.api.baseUrl != origin) {
      return;
    }
    AppSnack.success(context, 'تم تسجيل الطبيب بنجاح');
    await _loadAdminData();
  }

  Widget _status(String section) {
    if (_loading.contains(section)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }
    final error = _errors[section];
    if (error == null) return const SizedBox.shrink();
    final title = switch (section) {
      'overview' => ar ? 'تعذر تحميل الملخص' : 'Could not load summary',
      'users' => ar ? 'تعذر تحميل الحسابات' : 'Could not load accounts',
      _ => ar ? 'تعذر تحميل سجل التدقيق' : 'Could not load audit log',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            Text(error.message(AppLocalizations.of(context))),
            TextButton(
              onPressed: () => _load(section),
              child: Text(ar ? 'إعادة المحاولة' : 'Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _overview() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        ar ? 'إدارة النظام' : 'System administration',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 16),
      _status('overview'),
      if (_counts != null && !_errors.containsKey('overview')) ...[
        LayoutBuilder(
          builder: (context, box) => Wrap(
            spacing: 12,
            runSpacing: 12,
            children: ['patient', 'doctor', 'caregiver', 'admin']
                .map(
                  (role) => SizedBox(
                    width: box.maxWidth < 450
                        ? box.maxWidth
                        : (box.maxWidth - 12) / 2,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(switch (role) {
                              'patient' => ar ? 'المرضى' : 'Patients',
                              'doctor' => ar ? 'الأطباء' : 'Doctors',
                              'caregiver' => ar ? 'المرافقون' : 'Caregivers',
                              _ => ar ? 'المشرفون' : 'Administrators',
                            }),
                            Text(
                              '${(_counts!['byRole'] as Map)[role]}',
                              key: ValueKey('count-$role'),
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            ar
                ? 'تشمل الأعداد الحسابات المعطلة. إدارة الحسابات تعرض حالة كل حساب.'
                : 'Counts include disabled accounts. Account management shows each account’s status.',
          ),
        ),
      ],
      _shortcut(
        Icons.manage_accounts_outlined,
        ar ? 'إدارة الحسابات' : 'Manage accounts',
        Routes.adminAccounts,
      ),
      _shortcut(
        Icons.link_outlined,
        ar ? 'روابط الأطباء والمرافقين' : 'Doctor & caregiver links',
        Routes.adminLinks,
      ),
      _shortcut(
        Icons.devices_outlined,
        ar ? 'إدارة الأجهزة' : 'Manage devices',
        Routes.adminDevices,
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: _launching ? null : _launchPortal,
        icon: const Icon(Icons.open_in_new),
        label: Text(ar ? 'فتح بوابة الويب' : 'Open web portal'),
      ),
      Text(
        ar
            ? 'تحتاج بوابة الويب تسجيل دخول منفصلًا. لا تُرسل بيانات الجلسة في الرابط.'
            : 'The web portal requires separate sign-in. Session credentials are not sent in the URL.',
      ),
    ],
  );

  Widget _shortcut(IconData icon, String title, String route) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.pushNamed(context, route),
    ),
  );

  Widget _accounts() {
    final doctors = _users?.where((u) => u['role'] == 'doctor').toList();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _openAddDoctorDialog,
              icon: const Icon(Icons.person_add_outlined),
              label: Text(ar ? 'طبيب جديد' : 'New doctor'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pushNamed(context, Routes.adminLinks),
              child: Text(ar ? 'إدارة الروابط' : 'Manage links'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _status('users'),
        if (doctors != null && !_errors.containsKey('users')) ...[
          Text(
            ar ? 'الأطباء المسجلون' : 'Registered doctors',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (doctors.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                ar ? 'لا يوجد أطباء مسجلون' : 'No doctors registered',
              ),
            ),
          ...doctors.map(
            (doctor) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${doctor['name'] ?? doctor['username'] ?? ''}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${doctor['username'] ?? ''}${doctor['disabled'] == true ? (ar ? ' — معطل' : ' — disabled') : ''}',
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => Navigator.pushNamed(
                        context,
                        Routes.adminLinks,
                        arguments: doctor['id'],
                      ),
                      child: Text(ar ? 'عرض روابط الرعاية' : 'View care links'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _actor(Map<String, dynamic> row) {
    final id = row['actor']?.toString();
    final matches = _users?.where((u) => u['id'] == id);
    if (matches != null && matches.isNotEmpty) {
      return '${matches.first['name'] ?? id}';
    }
    return id == null || id.isEmpty
        ? (ar ? 'فاعل غير محدد' : 'Unspecified actor')
        : id;
  }

  String _time(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    return parsed == null
        ? (ar ? 'وقت غير متاح' : 'Time unavailable')
        : parsed.toLocal().toString().split('.').first;
  }

  Widget _auditLog() {
    final query = _filter.text.trim().toLowerCase();
    final rows = _audit
        ?.where(
          (row) => [
            'action',
            'actor',
            'actorRole',
            'target',
          ].any((key) => '${row[key] ?? ''}'.toLowerCase().contains(query)),
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          ar
              ? 'يعرض أحدث $_auditLimit عملية كحد أقصى؛ البحث ضمن السجلات المحمّلة فقط.'
              : 'Shows up to $_auditLimit recent events; search applies only to loaded records.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _filter,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: ar
                ? 'بحث بالعملية أو معرف الحساب أو الهدف'
                : 'Search action, account ID or target',
            prefixIcon: const Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: _auditLimit,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: ar ? 'عدد السجلات' : 'Record limit',
          ),
          items: [20, 100, 200]
              .map(
                (value) =>
                    DropdownMenuItem(value: value, child: Text('$value')),
              )
              .toList(),
          onChanged: _loading.contains('audit')
              ? null
              : (value) {
                  if (value != null) {
                    setState(() => _auditLimit = value);
                    _load('audit');
                  }
                },
        ),
        _status('audit'),
        if (rows != null && !_errors.containsKey('audit')) ...[
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                query.isEmpty
                    ? (ar ? 'لا توجد عمليات مسجلة' : 'No recorded events')
                    : (ar
                          ? 'لا توجد نتائج ضمن السجلات المحمّلة'
                          : 'No matches in loaded records'),
              ),
            ),
          ...rows.map(
            (row) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${row['action'] ?? (ar ? 'عملية غير محددة' : 'Unspecified action')}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text('${ar ? 'الحساب' : 'Account'}: ${_actor(row)}'),
                    if (row['actorRole'] != null)
                      Text('${ar ? 'الدور' : 'Role'}: ${row['actorRole']}'),
                    if (row['target'] != null && '${row['target']}'.isNotEmpty)
                      SelectableText(
                        '${ar ? 'الهدف' : 'Target'}: ${row['target']}',
                      ),
                    Text(_time(row['at'])),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    if (!_current()) return const SizedBox.shrink();
    return DefaultTabController(
      length: 3,
      child: WorkspaceScaffold(
        appBar: AppBar(
          title: Text(ar ? 'الإدارة' : 'Administration'),
          actions: [
            IconButton(
              tooltip: ar ? 'تحديث البيانات' : 'Refresh data',
              onPressed: _loading.isEmpty ? _loadAdminData : null,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: ar ? 'تسجيل الخروج' : 'Sign out',
              onPressed: () =>
                  confirmSignOut(context, context.read<AppState>()),
              icon: const Icon(Icons.logout),
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: ar ? 'الملخص' : 'Overview'),
              Tab(text: ar ? 'الأطباء والروابط' : 'Doctors & links'),
              Tab(text: ar ? 'سجل التدقيق' : 'Audit log'),
            ],
          ),
        ),
        body: ResponsiveContent(
          maxWidth: 1100,
          child: TabBarView(children: [_overview(), _accounts(), _auditLog()]),
        ),
      ),
    );
  }
}
