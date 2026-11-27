import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/enums.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';

/// Shared security gate for sensitive administrator operations.
///
/// Enforces biometric verification whenever available and enabled on the device,
/// otherwise falls back to an explicit confirmation dialog, while verifying
/// session owner and backend origin integrity before and after prompting.
Future<bool> requireAdminVerification(
  BuildContext context,
  String actionTitle,
) async {
  final app = context.read<AppState>();
  final ar = AppLocalizations.of(context).isArabic;
  final owner = app.auth.currentUser;
  final origin = app.api.baseUrl;
  if (owner?.role != UserRole.admin) return false;

  if (await app.biometrics.isAvailable && await app.biometrics.isEnabled()) {
    final accepted = await app.biometrics.authenticate(
      localizedReason: actionTitle,
    );
    return context.mounted &&
        accepted &&
        AppUser.sameSessionOwner(app.auth.currentUser, owner) &&
        app.api.baseUrl == origin;
  }

  if (!context.mounted ||
      !AppUser.sameSessionOwner(app.auth.currentUser, owner) ||
      app.api.baseUrl != origin) {
    return false;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ar ? 'تأكيد أمني للعملية' : 'Security confirmation'),
      content: Text(
        ar
            ? '$actionTitle\nسيتحقق الخادم من صلاحية حساب المشرف عند التنفيذ.'
            : '$actionTitle\nThe server verifies administrator privileges when this runs.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(ar ? 'إلغاء' : 'Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ar ? 'متابعة' : 'Continue'),
        ),
      ],
    ),
  );

  return context.mounted &&
      confirmed == true &&
      AppUser.sameSessionOwner(app.auth.currentUser, owner) &&
      app.api.baseUrl == origin;
}
