import 'package:flutter/material.dart';

import '../core/router/route_names.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/risk_view.dart';
import '../core/ui/common.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_state.dart';

/// Warns the patient *before* any seizure that the offline SMS/call fallback
/// has nobody to reach: no emergency contacts, or none with a usable number.
/// Re-checks whenever the care store changes (a contact added or edited).
///
/// [otherwise] is shown instead while there is no such problem, so the home
/// screen raises one setup warning at a time, the most important first.
class EmergencyContactsWarning extends StatefulWidget {
  const EmergencyContactsWarning({
    super.key,
    required this.app,
    this.otherwise,
  });

  final AppState app;
  final Widget? otherwise;

  @override
  State<EmergencyContactsWarning> createState() =>
      _EmergencyContactsWarningState();
}

class _EmergencyContactsWarningState extends State<EmergencyContactsWarning> {
  bool? _hasValid;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    widget.app.care.addListener(_check);
    _check();
  }

  @override
  void dispose() {
    widget.app.care.removeListener(_check);
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      final valid = await widget.app.validEmergencyContacts();
      if (mounted) setState(() => _hasValid = valid.isNotEmpty);
    } catch (_) {
      // Unknown: show nothing rather than a false alarm.
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasValid != false) return widget.otherwise ?? const SizedBox.shrink();
    final ar = AppLocalizations.of(context).isArabic;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoNote(
            text: ar
                ? 'لم تُضف أرقام طوارئ صالحة بعد. عند انقطاع الإنترنت يعتمد التطبيق على الرسائل النصية والاتصال المباشر، ولن يجد من يتواصل معه.'
                : 'No valid emergency numbers yet. Without internet the app relies on SMS and direct calls, and would have nobody to reach.',
            icon: Icons.contact_phone_outlined,
            view: RiskView.caution,
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: () =>
                  Navigator.pushNamed(context, Routes.patientEmergency),
              icon: const Icon(Icons.add_call),
              label: Text(ar ? 'إضافة أرقام الطوارئ' : 'Add emergency numbers'),
            ),
          ),
        ],
      ),
    );
  }
}
