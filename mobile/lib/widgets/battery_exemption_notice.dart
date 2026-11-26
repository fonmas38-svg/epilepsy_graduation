import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_spacing.dart';
import '../core/theme/risk_view.dart';
import '../core/ui/common.dart';
import '../l10n/app_localizations.dart';
import '../services/background_service.dart';

/// One-time reminder (Android only) to exempt the app from battery
/// optimization so monitoring and medication alarms are not stopped with the
/// screen off. Dismissal is remembered; the permissions screen keeps the
/// control available afterwards.
class BatteryExemptionNotice extends StatefulWidget {
  const BatteryExemptionNotice({super.key, required this.background});

  final BackgroundService background;

  static const dismissedKey = 'battery_exemption_prompt_dismissed';

  @override
  State<BatteryExemptionNotice> createState() => _BatteryExemptionNoticeState();
}

class _BatteryExemptionNoticeState extends State<BatteryExemptionNotice>
    with WidgetsBindingObserver {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (!widget.background.supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(BatteryExemptionNotice.dismissedKey) ?? false) {
        if (mounted && _show) setState(() => _show = false);
        return;
      }
      final exempt = await widget.background.isIgnoringBatteryOptimizations();
      if (mounted) setState(() => _show = !exempt);
    } catch (_) {}
  }

  Future<void> _dismiss() async {
    setState(() => _show = false);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(BatteryExemptionNotice.dismissedKey, true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final ar = AppLocalizations.of(context).isArabic;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoNote(
            text: ar
                ? 'قد يوقف وضع توفير البطارية الرصدَ في الخلفية ومنبهات الدواء عند إطفاء الشاشة. استثنِ التطبيق لضمان استمرار الحماية.'
                : 'Battery optimization may stop background monitoring and medication alarms when the screen is off. Exempt the app to keep protection running.',
            icon: Icons.battery_alert_outlined,
            view: RiskView.caution,
          ),
          // Same quiet text actions as the other setup notice: a warning
          // card should not carry the screen's heaviest button.
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Gap.xs,
            children: [
              TextButton(
                onPressed: _dismiss,
                child: Text(ar ? 'لاحقاً' : 'Later'),
              ),
              TextButton.icon(
                onPressed: () async {
                  await widget.background.requestIgnoreBatteryOptimizations();
                },
                icon: const Icon(Icons.battery_charging_full_outlined),
                label: Text(ar ? 'استثناء التطبيق' : 'Exempt the app'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
