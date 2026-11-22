import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/ui/common.dart';
import '../models/models.dart';
import '../providers/app_state.dart';

class CareSyncStatusCard extends StatefulWidget {
  const CareSyncStatusCard({super.key});
  @override
  State<CareSyncStatusCard> createState() => _CareSyncStatusCardState();
}

class _CareSyncStatusCardState extends State<CareSyncStatusCard> {
  late final AppState _app;
  late final AppUser? _owner;
  late final String _origin;
  late final int _revision;
  bool _busy = false, _loaded = false, _confirming = false;
  String? _error;
  bool get _ar => Localizations.localeOf(context).languageCode == 'ar';
  bool get _current =>
      mounted &&
      AppUser.sameSessionOwner(_owner, _app.auth.currentUser) &&
      _origin == _app.api.baseUrl &&
      _revision == _app.api.tokens.revision;
  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _owner = _app.auth.currentUser;
    _origin = _app.api.baseUrl;
    _revision = _app.api.tokens.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current) _refresh();
    });
  }

  Future<void> _refresh() async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      await _app.care.refreshOutboxStatus();
      if (_current) {
        setState(() {
          _loaded = true;
          _error = null;
        });
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _error = _ar
              ? 'تعذر قراءة حالة الحفظ. أعد المحاولة.'
              : 'Could not read saved delivery status. Try again.',
        );
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _retry() async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _confirming = true;
    });
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(_ar ? 'إعادة محاولة الإرسال؟' : 'Retry delivery?'),
        content: Text(
          _ar
              ? 'ستُعاد محاولة السجلات المحفوظة لهذا الحساب والخادم. يظل الإرسال معلقًا إن تعذر الاتصال أو رفض الخادم البيانات.'
              : 'Retry saved records for this account and server. Delivery remains pending if the connection fails or the server rejects the data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(_ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(_ar ? 'إعادة المحاولة' : 'Retry'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_current) {
      if (_current) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
      }
      return;
    }
    setState(() => _confirming = false);
    try {
      await _app.care.retryFailedWrites();
      if (_current) setState(() => _error = null);
    } catch (_) {
      if (_current) {
        setState(
          () => _error = _ar
              ? 'تعذرت إعادة المحاولة. لم تُحذف السجلات.'
              : 'Could not retry. Saved records were retained.',
        );
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      await _app.care.flushOutbox();
      if (!_current) return;
      await _app.care.refreshOutboxStatus();
      if (_current) setState(() => _error = null);
    } catch (_) {
      if (_current) {
        setState(
          () => _error = _ar
              ? 'تعذرت المزامنة. السجلات ما زالت محفوظة.'
              : 'Synchronization failed. Saved records were retained.',
        );
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    if (!_current || _owner == null) return const SizedBox.shrink();
    final care = _app.care;
    return SectionCard(
      title: _ar ? 'مزامنة الرعاية' : 'Care synchronization',
      icon: Icons.sync,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy && !_confirming) const LinearProgressIndicator(),
          if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
          if (_loaded) ...[
            Text(
              '${_ar ? 'بانتظار الإرسال' : 'Pending delivery'}: ${care.pendingCount}',
            ),
            Text(
              '${_ar ? 'تعذر إرساله' : 'Delivery stopped'}: ${care.failedOutboxCount}',
            ),
            Text(
              '${_ar ? 'بحاجة إلى تحقق من المصدر' : 'Source verification needed'}: ${care.heldOutboxCount}',
            ),
            if (care.heldOutboxCount > 0)
              Text(
                _ar
                    ? 'بعض السجلات تخص خادمًا آخر أو مصدرًا غير موثق. احتُفظ بها؛ راجع مسؤول النظام.'
                    : 'Some records belong to another or unknown server. They were retained; contact your administrator.',
              ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_loaded && care.pendingCount > 0)
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _sync,
                  icon: const Icon(Icons.sync),
                  label: Text(_ar ? 'مزامنة الآن' : 'Sync now'),
                ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: Text(_ar ? 'تحديث الحالة' : 'Refresh status'),
              ),
              if (_loaded && care.failedOutboxCount > 0)
                FilledButton(
                  onPressed: _busy ? null : _retry,
                  child: Text(_ar ? 'إعادة المحاولة' : 'Retry delivery'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
