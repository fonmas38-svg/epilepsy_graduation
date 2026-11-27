import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failure.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/utils/doctor_title_formatter.dart';
import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import 'admin_security_guard.dart';

/// Displays complete administrator-visible details for any user account,
/// including links, doctor MOH profile, and session revocation controls.
class AdminUserDetailSheet extends StatefulWidget {
  const AdminUserDetailSheet({super.key, required this.userId});

  final String userId;

  @override
  State<AdminUserDetailSheet> createState() => _AdminUserDetailSheetState();
}

class _AdminUserDetailSheetState extends State<AdminUserDetailSheet> {
  Map<String, dynamic>? _user;
  bool _loading = true;
  bool _busy = false;
  Failure? _failure;

  bool get ar => AppLocalizations.of(context).isArabic;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final data = await context.read<AppState>().api.getAdminUserDetails(
        widget.userId,
      );
      if (!mounted) return;
      setState(() => _user = data);
    } catch (e) {
      if (mounted) setState(() => _failure = Failure.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revokeSessions() async {
    final user = _user;
    if (user == null || _busy) return;
    final name = user['name']?.toString() ?? user['username']?.toString() ?? '';
    final verified = await requireAdminVerification(
      context,
      ar
          ? 'فك قفل الأجهزة وإنهاء جلسات الحساب $name'
          : 'Unlock devices and end sessions for $name',
    );
    if (!verified || !mounted) return;
    setState(() => _busy = true);
    try {
      final count = await context.read<AppState>().api.adminRevokeUserSessions(
        widget.userId,
      );
      if (!mounted) return;
      AppSnack.success(
        context,
        ar
            ? 'تم إنهاء $count جلسة وفك ربط الجهاز'
            : 'Ended $count sessions and unlocked device',
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

  Future<void> _reverifyMoh() async {
    final user = _user;
    if (user == null || _busy) return;
    final verified = await requireAdminVerification(
      context,
      ar
          ? 'إعادة التحقق من ترخيص الطبيب ${user['name'] ?? ''}'
          : 'Re-verify doctor license for ${user['name'] ?? ''}',
    );
    if (!verified || !mounted) return;
    setState(() => _busy = true);
    try {
      final res = await context.read<AppState>().api.reverifyDoctorMoh(
        widget.userId,
      );
      if (!mounted) return;
      final verification = res['verification'] as Map? ?? {};
      final msg =
          verification['message']?.toString() ??
          (ar ? 'تم تحديث حالة الترخيص' : 'License status updated');
      if (verification['verified'] == true) {
        AppSnack.success(context, msg);
      } else {
        AppSnack.warn(context, msg);
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
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    final meta = user?['meta'] as Map? ?? {};
    final profile = user?['doctorProfile'] as Map?;
    final role = user?['role']?.toString() ?? '';
    final isDisabled = user?['disabled'] == true;
    final createdAt = DateTime.tryParse('${user?['createdAt'] ?? ''}');
    final doctorIds = (user?['doctorIds'] as List? ?? []).cast<Object?>();
    final caregiverIds = (user?['caregiverIds'] as List? ?? []).cast<Object?>();
    final patientIds = (user?['patientIds'] as List? ?? []).cast<Object?>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      ar ? 'تفاصيل الحساب' : 'Account details',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (_loading) const LinearProgressIndicator(),
              if (_failure != null) ...[
                const SizedBox(height: 12),
                Text(_failure!.message(AppLocalizations.of(context))),
                TextButton(
                  onPressed: _load,
                  child: Text(ar ? 'إعادة المحاولة' : 'Retry'),
                ),
              ],
              if (user != null) ...[
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    role == 'doctor'
                        ? DoctorTitleFormatter.format(
                            '${user['name'] ?? ''}',
                            isArabic: ar,
                          )
                        : '${user['name'] ?? ''}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    '${user['username'] ?? ''} · $role',
                    textDirection: TextDirection.ltr,
                  ),
                  trailing: Chip(
                    label: Text(
                      isDisabled
                          ? (ar ? 'معطّل' : 'Disabled')
                          : (ar ? 'نشط' : 'Active'),
                    ),
                    backgroundColor: isDisabled
                        ? AppColors.of(context, RiskView.danger).container
                        : AppColors.accent(context, AccentTone.green).container,
                  ),
                ),
                const Divider(),
                if ('${user['email'] ?? ''}'.isNotEmpty)
                  _infoRow(
                    ar ? 'البريد الإلكتروني' : 'Email',
                    '${user['email']}',
                  ),
                if ('${meta['phone'] ?? ''}'.isNotEmpty)
                  _infoRow(ar ? 'الهاتف' : 'Phone', '${meta['phone']}'),
                if ('${meta['emergencyContact'] ?? ''}'.isNotEmpty)
                  _infoRow(
                    ar ? 'رقم الطوارئ' : 'Emergency contact',
                    '${meta['emergencyContact']}',
                  ),
                if ('${meta['diagnosis'] ?? ''}'.isNotEmpty)
                  _infoRow(
                    ar ? 'التشخيص' : 'Diagnosis',
                    '${meta['diagnosis']}',
                  ),
                if (createdAt != null)
                  _infoRow(
                    ar ? 'تاريخ الإنشاء' : 'Created',
                    TimeAgo.stamp(createdAt),
                  ),
                if (role == 'patient') ...[
                  _infoRow(
                    ar ? 'الأطباء المرتبطون' : 'Assigned doctors',
                    '${doctorIds.length}',
                  ),
                  _infoRow(
                    ar ? 'المرافقون المرتبطون' : 'Linked caregivers',
                    '${caregiverIds.length}',
                  ),
                ] else if (role == 'doctor' || role == 'caregiver')
                  _infoRow(
                    ar ? 'المرضى المرتبطون' : 'Linked patients',
                    '${patientIds.length}',
                  ),
                if (profile != null) ...[
                  const Divider(),
                  Text(
                    ar ? 'الملف المهني والتحقق (MOH)' : 'Medical Profile & MOH',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _infoRow(
                    ar ? 'رقم الترخيص' : 'License',
                    '${profile['licenseNumber'] ?? ''}',
                  ),
                  _infoRow(
                    ar ? 'التخصص' : 'Specialization',
                    '${profile['specialization'] ?? ''}',
                  ),
                  _infoRow(
                    ar ? 'المستشفى' : 'Hospital',
                    '${profile['hospitalAffiliation'] ?? ''}',
                  ),
                  _infoRow(
                    ar ? 'حالة الاعتماد' : 'Verification',
                    profile['mohVerified'] == true
                        ? (ar ? 'معتمد' : 'Verified')
                        : (ar
                              ? 'غير موثق (${profile['mohStatus'] ?? ''})'
                              : 'Unverified (${profile['mohStatus'] ?? ''})'),
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _revokeSessions,
                      icon: const Icon(Icons.devices_other_outlined),
                      label: Text(
                        ar
                            ? 'فك ربط الأجهزة وإنهاء الجلسات'
                            : 'Revoke sessions',
                      ),
                    ),
                    if (profile != null && profile['mohVerified'] != true)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _reverifyMoh,
                        icon: const Icon(Icons.verified_user_outlined),
                        label: Text(
                          ar ? 'إعادة التحقق من الترخيص' : 'Re-verify MOH',
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 135,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
