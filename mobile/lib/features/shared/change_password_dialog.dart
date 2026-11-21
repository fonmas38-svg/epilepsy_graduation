import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/router/route_names.dart';
import '../../providers/app_state.dart';
import '../../services/api_client.dart';

class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({super.key});
  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    if (_current.text.isEmpty ||
        _next.text.length < 12 ||
        _next.text != _confirm.text ||
        _next.text == _current.text) {
      setState(
        () => _error = ar
            ? 'أدخل الحالية، وكلمة مختلفة من 12 حرفًا على الأقل، مع تأكيد مطابق.'
            : 'Enter the current password and a different password of at least 12 characters with matching confirmation.',
      );
      return;
    }
    final app = context.read<AppState>();
    final owner = app.auth.currentUser?.uid;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await app.api.sendJson(
        method: 'POST',
        path: '/auth/password',
        body: {'current_password': _current.text, 'new_password': _next.text},
      );
      if (response['ok'] != true) {
        throw StateError('Password update was not acknowledged');
      }
      if (!mounted || app.auth.currentUser?.uid != owner) return;
      await app.biometrics.disableBiometrics();
      await app.signOut();
      if (mounted) {
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil(Routes.login, (_) => false);
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is ApiException && error.statusCode == 400
              ? (ar
                    ? 'تحقق من كلمة المرور الحالية واختر كلمة مختلفة.'
                    : 'Check the current password and choose a different password.')
              : (ar
                    ? 'تعذر تأكيد التغيير. حاول مجددًا أو سجّل الدخول إذا انتهت الجلسة.'
                    : 'Unable to confirm the change. Retry or sign in if the session expired.'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(ar ? 'تغيير كلمة المرور' : 'Change password'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ar
                      ? 'بعد التغيير ستحتاج إلى تسجيل الدخول مجددًا. تُرفض رموز الدخول القديمة عند اتصالها بالخادم.'
                      : 'After changing your password, sign in again. Old login tokens will be rejected by the server.',
                ),
                const SizedBox(height: 20),
                for (final field in [
                  (_current, ar ? 'كلمة المرور الحالية' : 'Current password'),
                  (
                    _next,
                    ar
                        ? 'كلمة جديدة (12 حرفًا على الأقل)'
                        : 'New password (at least 12 characters)',
                  ),
                  (_confirm, ar ? 'تأكيد كلمة المرور' : 'Confirm password'),
                ]) ...[
                  TextField(
                    controller: field.$1,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: InputDecoration(labelText: field.$2),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(
              _busy
                  ? (ar ? 'جارٍ الحفظ…' : 'Saving…')
                  : (ar ? 'تغيير وتسجيل الخروج' : 'Change & sign out'),
            ),
          ),
        ],
      ),
    );
  }
}
