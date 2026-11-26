import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import 'package:uuid/uuid.dart';
import '../../core/errors/failure.dart';
import '../../core/utils/username_generator.dart';
import '../../l10n/app_localizations.dart';

typedef CreateDoctor =
    Future<void> Function({
      required String name,
      required String username,
      required String password,
      String? phone,
    });

typedef CreateDoctorExtended =
    Future<void> Function({
      required String name,
      required String username,
      required String password,
      String? phone,
      String? email,
      String? licenseNumber,
      String? specialization,
      String? hospitalAffiliation,
      String? nationalId,
      bool mohOverride,
      required String idempotencyKey,
    });

typedef VerifyDoctorMoh =
    Future<Map<String, dynamic>> Function({
      required String licenseNumber,
      String? nationalId,
      String? name,
    });

class CreateDoctorDialog extends StatefulWidget {
  const CreateDoctorDialog({
    super.key,
    required this.create,
    this.createExtended,
    this.verifyMoh,
  });

  final CreateDoctor create;
  final CreateDoctorExtended? createExtended;
  final VerifyDoctorMoh? verifyMoh;

  @override
  State<CreateDoctorDialog> createState() => _CreateDoctorDialogState();
}

class _CreateDoctorDialogState extends State<CreateDoctorDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _licenseNumber = TextEditingController();
  final _specialization = TextEditingController();
  final _hospital = TextEditingController();
  final _nationalId = TextEditingController();
  late final String _idempotencyKey = const Uuid().v4();

  bool _usernameEditedManually = false;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _mohStatus;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';

  @override
  void initState() {
    super.initState();
    _name.addListener(_onNameChanged);
  }

  void _onNameChanged() {
    if (_usernameEditedManually || _busy) return;
    final generated = UsernameGenerator.generate(_name.text, prefix: 'dr');
    if (generated.isNotEmpty) {
      _username.value = TextEditingValue(
        text: generated,
        selection: TextSelection.collapsed(offset: generated.length),
      );
    }
  }

  @override
  void dispose() {
    _name.removeListener(_onNameChanged);
    for (final controller in [
      _name,
      _username,
      _password,
      _phone,
      _email,
      _licenseNumber,
      _specialization,
      _hospital,
      _nationalId,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<bool?> _confirmMohOverrideDialog(String message) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: AppColors.accent(context, AccentTone.orange).foreground,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ar
                    ? 'نتيجة التحقق من ترخيص وزارة الصحة'
                    : 'MOH License Verification Result',
              ),
            ),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ar ? 'إلغاء العملية' : 'Cancel operation'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              ar
                  ? 'إكمال الإنشاء على مسؤولية المدير'
                  : 'Complete creation under admin responsibility',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _checkMohOnly() async {
    final lic = _licenseNumber.text.trim();
    if (_busy || lic.isEmpty || widget.verifyMoh == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await widget.verifyMoh!(
        licenseNumber: lic,
        nationalId: _nationalId.text.trim().isEmpty
            ? null
            : _nationalId.text.trim(),
        name: _name.text.trim().isEmpty ? null : _name.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _mohStatus = res;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = Failure.from(error).message(AppLocalizations.of(context));
      });
    }
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var mohOverride = false;
      final lic = _licenseNumber.text.trim();
      if (widget.verifyMoh != null && lic.isNotEmpty) {
        final res = await widget.verifyMoh!(
          licenseNumber: lic,
          nationalId: _nationalId.text.trim().isEmpty
              ? null
              : _nationalId.text.trim(),
          name: _name.text.trim(),
        );
        if (!mounted) return;
        _mohStatus = res;
        final verified = res['verified'] == true;
        if (!verified) {
          setState(() => _busy = false);
          final override = await _confirmMohOverrideDialog(
            (res['message'] as String?) ??
                (ar
                    ? 'لم يتم التحقق من الترخيص في وزارة الصحة.'
                    : 'License could not be verified in MOH registry.'),
          );
          if (override != true || !mounted) return;
          mohOverride = true;
          setState(() => _busy = true);
        }
      }

      if (widget.createExtended != null) {
        await widget.createExtended!(
          name: _name.text.trim(),
          username: _username.text.trim(),
          password: _password.text,
          phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
          email: _email.text.trim().isEmpty ? null : _email.text.trim(),
          licenseNumber: lic.isEmpty ? null : lic,
          specialization: _specialization.text.trim().isEmpty
              ? null
              : _specialization.text.trim(),
          hospitalAffiliation: _hospital.text.trim().isEmpty
              ? null
              : _hospital.text.trim(),
          nationalId: _nationalId.text.trim().isEmpty
              ? null
              : _nationalId.text.trim(),
          mohOverride: mohOverride,
          idempotencyKey: _idempotencyKey,
        );
      } else {
        await widget.create(
          name: _name.text.trim(),
          username: _username.text.trim(),
          password: _password.text,
          phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        );
      }
      if (!mounted) return;
      setState(() => _busy = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.canPop(context)) Navigator.pop(context, true);
      });
    } catch (error) {
      if (!mounted) return;
      final failure = Failure.from(error);
      setState(() {
        _busy = false;
        _error = failure.kind == FailureKind.timeout
            ? (ar
                  ? 'تأخر الرد. قد يكون الحساب أُنشئ؛ تحقق من قائمة الحسابات قبل إعادة الإرسال.'
                  : 'The response timed out. The account may exist; check the accounts list before submitting again.')
            : failure.message(AppLocalizations.of(context));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(ar ? 'إنشاء حساب طبيب' : 'Create doctor account'),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Form(
            key: _form,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(color: colors.onErrorContainer),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_mohStatus != null) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _mohStatus!['verified'] == true
                          ? colors.primaryContainer
                          : colors.tertiaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      (_mohStatus!['message'] as String?) ?? '',
                      style: TextStyle(
                        color: _mohStatus!['verified'] == true
                            ? colors.onPrimaryContainer
                            : colors.onTertiaryContainer,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _name,
                  readOnly: _busy,
                  maxLength: 120,
                  decoration: InputDecoration(
                    labelText: ar ? 'اسم الطبيب *' : 'Doctor name *',
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? (ar ? 'أدخل اسم الطبيب' : 'Enter the doctor name')
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _username,
                  readOnly: _busy,
                  maxLength: 64,
                  autocorrect: false,
                  onChanged: (_) => _usernameEditedManually = true,
                  decoration: InputDecoration(
                    labelText: ar ? 'اسم المستخدم *' : 'Username *',
                    helperText: ar
                        ? 'يُولّد تلقائياً من الاسم ويمكنك تعديله'
                        : 'Auto-generated from name and editable',
                    prefixIcon: const Icon(Icons.badge_outlined),
                  ),
                  validator: (value) => (value?.trim().length ?? 0) < 3
                      ? (ar
                            ? 'استخدم 3 أحرف على الأقل'
                            : 'Use at least 3 characters')
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  readOnly: _busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 128,
                  decoration: InputDecoration(
                    labelText: ar ? 'كلمة المرور *' : 'Password *',
                    helperText: ar ? 'من 6 إلى 128 حرفًا' : '6–128 characters',
                    prefixIcon: const Icon(Icons.lock_outline),
                  ),
                  validator: (value) => (value?.length ?? 0) < 6
                      ? (ar
                            ? 'استخدم 6 أحرف على الأقل'
                            : 'Use at least 6 characters')
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  validator: (v) =>
                      RegExp(r'^\+?[0-9]{8,15}$').hasMatch(v?.trim() ?? '')
                      ? null
                      : (ar
                            ? 'أدخل رقم هاتف صالحاً'
                            : 'Enter a valid phone number'),
                  readOnly: _busy,
                  maxLength: 32,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: ar ? 'الهاتف *' : 'Phone *',
                    prefixIcon: const Icon(Icons.phone_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  readOnly: _busy,
                  maxLength: 254,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: ar
                        ? 'البريد الإلكتروني (اختياري)'
                        : 'Email (optional)',
                    prefixIcon: const Icon(Icons.email_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                ExpansionTile(
                  initiallyExpanded: true,
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    ar
                        ? 'بيانات الترخيص المطلوبة — سجل تحقق تجريبي'
                        : 'Required license details — simulated registry',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  children: [
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _licenseNumber,
                      validator: (v) => v == null || v.trim().isEmpty
                          ? (ar ? 'هذا الحقل مطلوب' : 'Required field')
                          : null,
                      readOnly: _busy,
                      maxLength: 64,
                      decoration: InputDecoration(
                        labelText: ar
                            ? 'رقم الترخيص المهني (MOH)'
                            : 'MOH License Number',
                        hintText: 'MOH-100200',
                        prefixIcon: const Icon(Icons.verified_user_outlined),
                        suffixIcon: widget.verifyMoh == null
                            ? null
                            : IconButton(
                                tooltip: ar
                                    ? 'تحقق من وزارة الصحة'
                                    : 'Verify with MOH',
                                onPressed: _busy ? null : _checkMohOnly,
                                icon: const Icon(Icons.fact_check_outlined),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _nationalId,
                      validator: (v) => v == null || v.trim().isEmpty
                          ? (ar ? 'هذا الحقل مطلوب' : 'Required field')
                          : null,
                      readOnly: _busy,
                      maxLength: 32,
                      decoration: InputDecoration(
                        labelText: ar ? 'رقم الهوية الوطنية' : 'National ID',
                        prefixIcon: const Icon(Icons.credit_card_outlined),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _specialization,
                      validator: (v) => v == null || v.trim().isEmpty
                          ? (ar ? 'هذا الحقل مطلوب' : 'Required field')
                          : null,
                      readOnly: _busy,
                      maxLength: 120,
                      decoration: InputDecoration(
                        labelText: ar
                            ? 'التخصص الطبي'
                            : 'Medical Specialization',
                        prefixIcon: const Icon(Icons.medical_services_outlined),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _hospital,
                      validator: (v) => v == null || v.trim().isEmpty
                          ? (ar ? 'هذا الحقل مطلوب' : 'Required field')
                          : null,
                      readOnly: _busy,
                      maxLength: 180,
                      decoration: InputDecoration(
                        labelText: ar
                            ? 'المستشفى / الجهة الطبية'
                            : 'Hospital Affiliation',
                        prefixIcon: const Icon(Icons.local_hospital_outlined),
                      ),
                    ),
                  ],
                ),
                if (_busy)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      ar ? 'جارٍ إنشاء الحساب…' : 'Creating account…',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: Text(ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(ar ? 'إنشاء الحساب' : 'Create account'),
          ),
        ],
      ),
    );
  }
}
