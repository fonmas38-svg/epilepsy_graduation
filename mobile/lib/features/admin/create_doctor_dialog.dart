import 'package:flutter/material.dart';
import '../../core/errors/failure.dart';
import '../../l10n/app_localizations.dart';

typedef CreateDoctor =
    Future<void> Function({
      required String name,
      required String username,
      required String password,
      String? phone,
    });

class CreateDoctorDialog extends StatefulWidget {
  const CreateDoctorDialog({super.key, required this.create});
  final CreateDoctor create;
  @override
  State<CreateDoctorDialog> createState() => _CreateDoctorDialogState();
}

class _CreateDoctorDialogState extends State<CreateDoctorDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';

  @override
  void dispose() {
    for (final controller in [_name, _username, _password, _phone]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.create(
        name: _name.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      );
      if (!mounted) return;
      setState(() => _busy = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
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
          width: 420,
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
                  decoration: InputDecoration(
                    labelText: ar ? 'اسم المستخدم *' : 'Username *',
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
                  readOnly: _busy,
                  maxLength: 32,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: ar ? 'الهاتف (اختياري)' : 'Phone (optional)',
                    prefixIcon: const Icon(Icons.phone_outlined),
                  ),
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
