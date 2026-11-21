import 'package:flutter/material.dart';
import '../../providers/app_state.dart';
import '../enums.dart';
import '../router/route_names.dart';

/// Signing out is an explicit action, never a consequence of closing a page.
Future<void> confirmSignOut(BuildContext context, AppState app) async {
  final ar = Localizations.localeOf(context).languageCode == 'ar';
  final patient = app.auth.currentUser?.role == UserRole.patient;
  final owner = app.auth.currentUser;
  final origin = app.api.baseUrl;
  final revision = app.api.tokens.revision;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(ar ? 'تسجيل الخروج؟' : 'Sign out?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ar
                  ? 'ستحتاج إلى تسجيل الدخول مجددًا لاستخدام حسابك.'
                  : 'You will need to sign in again to use your account.',
            ),
            if (patient) ...[
              const SizedBox(height: 12),
              Text(
                ar
                    ? 'ستتوقف المراقبة المحلية المرتبطة بحسابك على هذا الجهاز.'
                    : 'Local monitoring for this account will stop on this device.',
              ),
            ],
            const SizedBox(height: 12),
            Text(
              ar
                  ? 'البيانات المحفوظة محليًا لا تُحذف بهذا الإجراء. مزامنتها مرتبطة بالحساب وصلاحياته.'
                  : 'This action does not delete locally stored data. Synchronization remains subject to account authorization.',
            ),
            if (!app.apiOnline) ...[
              const SizedBox(height: 12),
              Text(
                ar
                    ? 'دون اتصال يُمسح الدخول من هذا الجهاز فقط. إلغاء الجلسة على الخادم يحتاج اتصالًا، أو إلغاءها من جهاز آخر.'
                    : 'Offline logout clears this device only. Revoking the server session requires a connection or another signed-in device.',
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: Text(ar ? 'البقاء' : 'Stay'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(ar ? 'تسجيل الخروج' : 'Sign out'),
        ),
      ],
    ),
  );
  if (confirmed != true ||
      !context.mounted ||
      !identical(app.auth.currentUser, owner) ||
      app.api.baseUrl != origin ||
      app.api.tokens.revision != revision) {
    return;
  }
  await app.signOut();
  if (context.mounted) {
    Navigator.pushNamedAndRemoveUntil(context, Routes.login, (_) => false);
  }
}
