import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failure.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import 'admin_security_guard.dart';

/// Displays cloud backend health, ML engine status, and alert outbox delivery
/// metrics with administrator retry controls.
class SystemHealthScreen extends StatefulWidget {
  const SystemHealthScreen({super.key});

  @override
  State<SystemHealthScreen> createState() => _SystemHealthScreenState();
}

class _SystemHealthScreenState extends State<SystemHealthScreen> {
  Map<String, dynamic>? _health;
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
      final data = await context.read<AppState>().api.getAdminSystemHealth();
      if (!mounted) return;
      setState(() => _health = data);
    } catch (e) {
      if (mounted) setState(() => _failure = Failure.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _retryFailedOutbox() async {
    if (_busy) return;
    final verified = await requireAdminVerification(
      context,
      ar
          ? 'إعادة جدولة التنبيهات الفاشلة في طابور الإرسال'
          : 'Re-queue failed alerts in delivery outbox',
    );
    if (!verified || !mounted) return;
    setState(() => _busy = true);
    try {
      final retried = await context.read<AppState>().api.retryAdminOutbox();
      if (!mounted) return;
      AppSnack.success(
        context,
        ar ? 'تمت إعادة جدولة $retried تنبيه' : 'Re-queued $retried alerts',
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

  @override
  Widget build(BuildContext context) {
    final health = _health;
    final ml = health?['ml'] as Map? ?? {};
    final outbox = health?['outbox'] as Map? ?? {};
    final db = health?['database'] as Map? ?? {};
    final errors = (outbox['recentErrors'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final failedCount =
        ((outbox['failed'] as num?)?.toInt() ?? 0) +
        ((outbox['dead'] as num?)?.toInt() ?? 0);

    return Scaffold(
      appBar: AppBar(
        title: Text(ar ? 'صحة النظام والذكاء الاصطناعي' : 'System & AI Health'),
        actions: [
          IconButton(
            tooltip: ar ? 'تحديث' : 'Refresh',
            onPressed: _loading || _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ResponsiveContent(
        maxWidth: 960,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_loading || _busy) const LinearProgressIndicator(),
            if (_failure != null) ...[
              Text(_failure!.message(AppLocalizations.of(context))),
              TextButton(
                onPressed: _load,
                child: Text(ar ? 'إعادة المحاولة' : 'Retry'),
              ),
            ],
            if (health != null) ...[
              SectionCard(
                title: ar ? 'البنية التشغيلية' : 'Runtime Infrastructure',
                icon: Icons.dns_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv(
                      ar ? 'بيئة التشغيل' : 'Environment',
                      '${health['environment'] ?? ''}',
                    ),
                    _kv(
                      ar ? 'قاعدة البيانات' : 'Database',
                      '${db['backend'] ?? ''}',
                    ),
                    _kv(
                      ar ? 'قناة الإشعارات' : 'Notification channel',
                      '${health['notificationChannel'] ?? ''}',
                    ),
                    _kv(
                      ar ? 'محرك الذكاء الاصطناعي' : 'Active AI engine',
                      '${ml['active_engine'] ?? 'unknown'}',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: ar
                    ? 'طابور إرسال التنبيهات (Outbox)'
                    : 'Alert Delivery Outbox',
                icon: Icons.notifications_active_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        _statChip(
                          ar
                              ? 'قيد الانتظار: ${outbox['pending'] ?? 0}'
                              : 'Pending: ${outbox['pending'] ?? 0}',
                          AppColors.of(context, RiskView.caution).container,
                        ),
                        _statChip(
                          ar
                              ? 'مُرسل: ${outbox['sent'] ?? 0}'
                              : 'Sent: ${outbox['sent'] ?? 0}',
                          AppColors.accent(context, AccentTone.green).container,
                        ),
                        _statChip(
                          ar
                              ? 'فاشل/متوقف: $failedCount'
                              : 'Failed/Dead: $failedCount',
                          failedCount > 0
                              ? AppColors.of(context, RiskView.danger).container
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: _busy || failedCount == 0
                          ? null
                          : _retryFailedOutbox,
                      icon: const Icon(Icons.replay_outlined),
                      label: Text(
                        ar
                            ? 'إعادة محاولة الإرسال الفاشلة'
                            : 'Retry failed deliveries',
                      ),
                    ),
                    if (errors.isNotEmpty) ...[
                      const Divider(height: 24),
                      Text(
                        ar ? 'أحدث أخطاء الإرسال' : 'Recent delivery errors',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      ...errors.map(
                        (e) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${e['alertId'] ?? ''} (${e['status'] ?? ''})',
                          ),
                          subtitle: Text('${e['lastError'] ?? ''}'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: 170,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  Widget _statChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
  );
}
