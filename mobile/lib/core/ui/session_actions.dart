import 'package:flutter/material.dart';
import '../../models/models.dart';
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
            // The safety consequence first; the rest kept to one line each.
            if (patient) ...[
              Text(
                ar
                    ? 'ستتوقف المراقبة على هذا الجهاز حتى تسجّل الدخول مجددًا.'
                    : 'Monitoring stops on this device until you sign in again.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              ar
                  ? 'بياناتك المحفوظة على الجهاز لن تُحذف.'
                  : 'Data saved on this device is not deleted.',
            ),
            if (!app.apiOnline) ...[
              const SizedBox(height: 12),
              Text(
                ar
                    ? 'دون اتصال، يُلغى الدخول من هذا الجهاز فقط.'
                    : 'Offline, this signs out this device only.',
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
      !AppUser.sameSessionOwner(app.auth.currentUser, owner) ||
      app.api.baseUrl != origin ||
      app.api.tokens.revision != revision) {
    return;
  }
  await app.signOut();
  if (context.mounted) {
    Navigator.pushNamedAndRemoveUntil(context, Routes.login, (_) => false);
  }
}
