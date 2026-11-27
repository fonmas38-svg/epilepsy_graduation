import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import '../../core/utils/doctor_title_formatter.dart';
import '../../core/utils/time_ago.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/enums.dart';
import '../../core/errors/failure.dart';
import '../../core/router/route_names.dart';
import '../../core/ui/common.dart';
import '../../core/ui/session_actions.dart';
import '../../core/ui/workspace_scaffold.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../shared/account_screen.dart';
import 'admin_security_guard.dart';
import 'admin_user_detail_sheet.dart';
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
  final _doctorSearch = TextEditingController();
  AppUser? _owner;
  String? _origin;
  String _doctorStatusFilter = '';
  String _auditRoleFilter = '';
  int _auditLimit = 20;
  int _section = 0;
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
    _doctorSearch.dispose();
    super.dispose();
  }

  bool _current() {
    final app = context.read<AppState>();
    return mounted &&
        AppUser.sameSessionOwner(app.auth.currentUser, _owner) &&
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
      if (section == 'audit') {
        final rows = await app.api.getAdminAudit(
          limit: _auditLimit,
          actorRole: _auditRoleFilter.isEmpty ? null : _auditRoleFilter,
          query: _filter.text.trim(),
        );
        if (!_current() || _revisions[section] != revision) return;
        setState(() => _audit = rows);
        return;
      }
      final path = switch (section) {
        'overview' => '/admin/overview',
        _ => '/admin/users',
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
        rows = _rows(body, 'users');
      }
      if (!_current() || _revisions[section] != revision) return;
      setState(() {
        if (section == 'overview') _counts = counts;
        if (section == 'users') _users = rows;
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

  Future<bool> _requireAdminSecurityVerification(String actionTitle) =>
      requireAdminVerification(context, actionTitle);

  Future<void> _toggleDoctorDisabled(Map<String, dynamic> doctor) async {
    final docId = doctor['id']?.toString() ?? '';
    final name = doctor['name'] ?? doctor['username'] ?? '';
    final isDisabled = doctor['disabled'] == true;
    final actionText = isDisabled
        ? 'تفعيل حساب الطبيب $name'
        : 'تعطيل حساب الطبيب $name';
    final verified = await _requireAdminSecurityVerification(actionText);
    if (!verified || !mounted) return;

    final app = context.read<AppState>();
    try {
      if (isDisabled) {
        await app.api.adminEnableUser(docId);
        if (mounted) {
          AppSnack.success(
            context,
            (ar ? 'تم تفعيل حساب الطبيب' : 'Doctor account enabled'),
          );
        }
      } else {
        await app.api.adminDisableUser(docId);
        if (mounted) {
          AppSnack.success(
            context,
            (ar ? 'تم تعطيل حساب الطبيب' : 'Doctor account disabled'),
          );
        }
      }
      await _load('users');
    } catch (e) {
      if (mounted) {
        AppSnack.error(
          context,
          Failure.from(e).message(AppLocalizations.of(context)),
        );
      }
    }
  }

  Future<void> _resetDoctorPassword(Map<String, dynamic> doctor) async {
    final docId = doctor['id']?.toString() ?? '';
    final name = doctor['name'] ?? doctor['username'] ?? '';
    final verified = await _requireAdminSecurityVerification(
      ar
          ? 'إعادة تعيين كلمة مرور الطبيب $name'
          : 'Reset the password of doctor $name',
    );
    if (!verified || !mounted) return;

    final app = context.read<AppState>();
    try {
      final generated = await app.api.adminResetUserPassword(docId);
      if (!mounted) return;
      if (generated != null && generated.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(
              (ar ? 'كلمة المرور المؤقتة الجديدة' : 'New temporary password'),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ar
                      ? 'تم توليد كلمة مرور جديدة للطبيب "$name":'
                      : 'A new password was generated for doctor "$name":',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  generated,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  ar
                      ? 'يرجى نسخ كلمة المرور ومشاركتها مع الطبيب بشكل آمن. لن تظهر مجدداً.'
                      : 'Copy the password and share it with the doctor securely. It will not be shown again.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text((ar ? 'تم الحفظ' : 'Saved')),
              ),
            ],
          ),
        );
      } else {
        AppSnack.success(
          context,
          (ar ? 'تمت إعادة تعيين كلمة المرور' : 'Password reset'),
        );
      }
      await _loadAdminData();
    } catch (e) {
      if (mounted) {
        AppSnack.error(
          context,
          Failure.from(e).message(AppLocalizations.of(context)),
        );
      }
    }
  }

  Future<void> _deleteDoctor(Map<String, dynamic> doctor) async {
    final docId = doctor['id']?.toString() ?? '';
    final name = doctor['name'] ?? doctor['username'] ?? '';
    final verified = await _requireAdminSecurityVerification(
      ar
          ? 'الحذف النهائي لحساب الطبيب $name وإلغاء كافة إسناداته'
          : 'Permanently delete doctor $name and remove all assignments',
    );
    if (!verified || !mounted) return;

    final app = context.read<AppState>();
    try {
      await app.api.adminDeleteUser(docId);
      if (mounted) {
        AppSnack.success(
          context,
          (ar ? 'تم حذف حساب الطبيب نهائياً' : 'Doctor account deleted'),
        );
      }
      await _loadAdminData();
    } catch (e) {
      if (mounted) {
        AppSnack.error(
          context,
          Failure.from(e).message(AppLocalizations.of(context)),
        );
      }
    }
  }

  Future<void> _revokeDoctorSessions(Map<String, dynamic> doctor) async {
    final docId = doctor['id']?.toString() ?? '';
    final name = doctor['name'] ?? doctor['username'] ?? '';
    final verified = await _requireAdminSecurityVerification(
      ar
          ? 'فك قفل الأجهزة والجلسات للحساب $name'
          : 'Unlock devices and sessions for $name',
    );
    if (!verified || !mounted) return;

    final app = context.read<AppState>();
    try {
      final revoked = await app.api.adminRevokeUserSessions(docId);
      if (mounted) {
        AppSnack.success(
          context,
          ar
              ? 'تم إنهاء $revoked جلسة وفك قفل الجهاز'
              : 'Ended $revoked sessions and unlocked the device',
        );
      }
      await _loadAdminData();
    } catch (e) {
      if (mounted) {
        AppSnack.error(
          context,
          Failure.from(e).message(AppLocalizations.of(context)),
        );
      }
    }
  }

  Future<void> _openAddDoctorDialog() async {
    final verified = await _requireAdminSecurityVerification(
      (ar ? 'إضافة طبيب معالج جديد' : 'Add a new treating doctor'),
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
              if (!AppUser.sameSessionOwner(app.auth.currentUser, owner) ||
                  app.api.baseUrl != origin) {
                throw const Failure(FailureKind.unauthorized);
              }
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
              if (!AppUser.sameSessionOwner(app.auth.currentUser, owner) ||
                  app.api.baseUrl != origin) {
                throw const Failure(FailureKind.unauthorized);
              }
            },
        create:
            ({
              required name,
              required username,
              required password,
              phone,
            }) async {
              if (!AppUser.sameSessionOwner(app.auth.currentUser, owner) ||
                  app.api.baseUrl != origin) {
                throw const Failure(FailureKind.unauthorized);
              }
              await app.api.createAdminDoctor(
                name: name,
                username: username,
                password: password,
                phone: phone,
              );
              if (!AppUser.sameSessionOwner(app.auth.currentUser, owner) ||
                  app.api.baseUrl != origin) {
                throw const Failure(FailureKind.unauthorized);
              }
            },
      ),
    );
    if (!mounted ||
        created != true ||
        !AppUser.sameSessionOwner(app.auth.currentUser, owner) ||
        app.api.baseUrl != origin) {
      return;
    }
    AppSnack.success(context, (ar ? 'تم تسجيل الطبيب' : 'Doctor registered'));
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
        if (_counts!['devices'] is Map) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                avatar: const Icon(Icons.devices_outlined, size: 16),
                label: Text(
                  ar
                      ? 'الأجهزة: ${(_counts!['devices'] as Map)['total'] ?? 0} (معطّل ${(_counts!['devices'] as Map)['disabled'] ?? 0})'
                      : 'Devices: ${(_counts!['devices'] as Map)['total'] ?? 0} (disabled ${(_counts!['devices'] as Map)['disabled'] ?? 0})',
                ),
              ),
              if ((_counts!['pendingDeletionRequests'] as num? ?? 0) > 0)
                Chip(
                  avatar: const Icon(Icons.person_remove_outlined, size: 16),
                  label: Text(
                    ar
                        ? 'طلبات حذف معلّقة: ${_counts!['pendingDeletionRequests']}'
                        : 'Pending erasures: ${_counts!['pendingDeletionRequests']}',
                  ),
                ),
              if ((_counts!['mohOverrides'] as num? ?? 0) > 0)
                Chip(
                  avatar: const Icon(Icons.verified_user_outlined, size: 16),
                  label: Text(
                    ar
                        ? 'تجاوزات تراخيص MOH: ${_counts!['mohOverrides']}'
                        : 'MOH overrides: ${_counts!['mohOverrides']}',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
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
      _shortcut(
        Icons.person_remove_outlined,
        ar ? 'طلبات حذف الحسابات' : 'Account erasure requests',
        Routes.privacyRequests,
      ),
      _shortcut(
        Icons.monitor_heart_outlined,
        ar ? 'صحة النظام والذكاء الاصطناعي' : 'System & AI health',
        Routes.adminSystemHealth,
      ),
      _shortcut(
        Icons.verified_outlined,
        ar ? 'سجل التراخيص الطبية (MOH)' : 'MOH license registry',
        Routes.adminMohRegistry,
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
    final docQuery = _doctorSearch.text.trim().toLowerCase();
    final doctors = _users?.where((u) {
      if (u['role'] != 'doctor') return false;
      final isDisabled = u['disabled'] == true;
      if (_doctorStatusFilter == 'enabled' && isDisabled) return false;
      if (_doctorStatusFilter == 'disabled' && !isDisabled) return false;
      if (docQuery.isEmpty) return true;
      final meta = u['meta'] as Map? ?? {};
      final text = [
        u['name'],
        u['username'],
        u['email'],
        meta['licenseNumber'],
        meta['specialization'],
        meta['hospitalAffiliation'],
      ].whereType<Object>().map((v) => v.toString().toLowerCase()).join(' ');
      return text.contains(docQuery);
    }).toList();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              // Creating an account needs the server; offline it could only
              // fail after the security check (same rule as «Create account»).
              onPressed: context.read<AppState>().apiOnline
                  ? _openAddDoctorDialog
                  : null,
              icon: const Icon(Icons.person_add_outlined),
              label: Text(ar ? 'طبيب جديد' : 'New doctor'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pushNamed(context, Routes.adminLinks),
              child: Text(ar ? 'إدارة الروابط' : 'Manage links'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _doctorSearch,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: ar
                ? 'بحث باسم الطبيب أو الترخيص أو التخصص'
                : 'Search doctor name, license or specialty',
            prefixIcon: const Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final entry in [
              ('', ar ? 'الكل' : 'All'),
              ('enabled', ar ? 'نشط' : 'Active'),
              ('disabled', ar ? 'معطّل' : 'Disabled'),
            ])
              ChoiceChip(
                label: Text(entry.$2),
                selected: _doctorStatusFilter == entry.$1,
                onSelected: (_) =>
                    setState(() => _doctorStatusFilter = entry.$1),
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
          ...doctors.map((doctor) {
            final isDisabled = doctor['disabled'] == true;
            final meta = doctor['meta'] as Map? ?? {};
            final license = meta['licenseNumber']?.toString() ?? '';
            final spec = meta['specialization']?.toString() ?? '';
            final hospital = meta['hospitalAffiliation']?.toString() ?? '';

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: isDisabled
                              ? AppColors.of(context, RiskView.danger).border
                              : AppColors.accent(
                                  context,
                                  AccentTone.blue,
                                ).container,
                          child: Icon(
                            Icons.medical_services_outlined,
                            color: isDisabled
                                ? AppColors.of(
                                    context,
                                    RiskView.danger,
                                  ).foreground
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                DoctorTitleFormatter.format(
                                  '${doctor['name'] ?? doctor['username'] ?? ''}',
                                  isArabic: ar,
                                ),
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${doctor['username'] ?? ''}',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isDisabled)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.of(
                                context,
                                RiskView.danger,
                              ).container,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: AppColors.of(
                                  context,
                                  RiskView.danger,
                                ).border,
                              ),
                            ),
                            child: Text(
                              ar ? 'معطّل' : 'Disabled',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.of(
                                  context,
                                  RiskView.danger,
                                ).foreground,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.accent(
                                context,
                                AccentTone.green,
                              ).container,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: AppColors.of(
                                  context,
                                  RiskView.safe,
                                ).border,
                              ),
                            ),
                            child: Text(
                              ar ? 'نشط' : 'Active',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.accent(
                                  context,
                                  AccentTone.green,
                                ).foreground,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (license.isNotEmpty ||
                        spec.isNotEmpty ||
                        hospital.isNotEmpty) ...[
                      const Divider(height: 20),
                      Wrap(
                        spacing: 12,
                        runSpacing: 6,
                        children: [
                          if (license.isNotEmpty)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.verified_outlined,
                                  size: 14,
                                  color: AppColors.accent(
                                    context,
                                    AccentTone.green,
                                  ).foreground,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'MOH: $license',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.accent(
                                      context,
                                      AccentTone.green,
                                    ).foreground,
                                  ),
                                ),
                              ],
                            ),
                          if (spec.isNotEmpty)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.badge_outlined,
                                  size: 14,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  spec,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          if (hospital.isNotEmpty)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.local_hospital_outlined,
                                  size: 14,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  hospital,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) =>
                                AdminUserDetailSheet(userId: '${doctor['id']}'),
                          ),
                          icon: const Icon(Icons.info_outline, size: 16),
                          label: Text(ar ? 'التفاصيل' : 'Details'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.pushNamed(
                            context,
                            Routes.adminLinks,
                            arguments: doctor['id'],
                          ),
                          icon: const Icon(Icons.people_alt_outlined, size: 16),
                          label: Text(ar ? 'المرضى' : 'Patients'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _resetDoctorPassword(doctor),
                          icon: const Icon(Icons.password_outlined, size: 16),
                          label: Text(ar ? 'كلمة المرور' : 'Password'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _revokeDoctorSessions(doctor),
                          icon: const Icon(
                            Icons.devices_other_outlined,
                            size: 16,
                          ),
                          label: Text(ar ? 'فك ربط الأجهزة' : 'Revoke device'),
                        ),
                        if (isDisabled)
                          FilledButton.tonalIcon(
                            onPressed: () => _toggleDoctorDisabled(doctor),
                            icon: const Icon(
                              Icons.check_circle_outline,
                              size: 16,
                            ),
                            label: Text(ar ? 'تفعيل' : 'Enable'),
                          )
                        else
                          OutlinedButton.icon(
                            onPressed: () => _toggleDoctorDisabled(doctor),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.of(
                                context,
                                RiskView.caution,
                              ).foreground,
                            ),
                            icon: const Icon(Icons.block_outlined, size: 16),
                            label: Text(ar ? 'تعطيل' : 'Disable'),
                          ),
                        IconButton(
                          tooltip: ar ? 'حذف الحساب نهائياً' : 'Delete account',
                          onPressed: () => _deleteDoctor(doctor),
                          icon: Icon(
                            Icons.delete_forever_outlined,
                            color: AppColors.of(
                              context,
                              RiskView.danger,
                            ).foreground,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
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
        : TimeAgo.stamp(parsed);
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
          onSubmitted: (_) => _load('audit'),
          decoration: InputDecoration(
            labelText: ar
                ? 'بحث بالعملية أو معرف الحساب أو الهدف'
                : 'Search action, account ID or target',
            prefixIcon: const Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _auditRoleFilter,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: ar ? 'الدور المنفّذ' : 'Actor role',
                ),
                items: [
                  DropdownMenuItem(value: '', child: Text(ar ? 'الكل' : 'All')),
                  DropdownMenuItem(
                    value: 'admin',
                    child: Text(ar ? 'مشرف' : 'Admin'),
                  ),
                  DropdownMenuItem(
                    value: 'doctor',
                    child: Text(ar ? 'طبيب' : 'Doctor'),
                  ),
                  DropdownMenuItem(
                    value: 'patient',
                    child: Text(ar ? 'مريض' : 'Patient'),
                  ),
                  DropdownMenuItem(
                    value: 'caregiver',
                    child: Text(ar ? 'مرافق' : 'Caregiver'),
                  ),
                ],
                onChanged: _loading.contains('audit')
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _auditRoleFilter = value);
                          _load('audit');
                        }
                      },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
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
            ),
          ],
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
    return WorkspaceScaffold(
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
            onPressed: () => confirmSignOut(context, context.read<AppState>()),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      selectedIndex: _section,
      onDestinationSelected: (index) => setState(() => _section = index),
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.dashboard_outlined),
          label: ar ? 'الملخص' : 'Overview',
        ),
        NavigationDestination(
          icon: const Icon(Icons.people_outline),
          label: ar ? 'الأطباء والروابط' : 'Doctors & links',
        ),
        NavigationDestination(
          icon: const Icon(Icons.history),
          label: ar ? 'سجل التدقيق' : 'Audit log',
        ),
        NavigationDestination(
          icon: const Icon(Icons.person_outline),
          label: ar ? 'حسابي' : 'Account',
        ),
      ],
      body: ResponsiveContent(
        maxWidth: 1100,
        child: IndexedStack(
          index: _section,
          children: [
            _overview(),
            _accounts(),
            _auditLog(),
            const AccountScreen(embedded: true),
          ],
        ),
      ),
    );
  }
}
