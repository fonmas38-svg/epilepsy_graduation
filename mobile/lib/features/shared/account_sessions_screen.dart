import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/errors/failure.dart';
import '../../core/router/route_names.dart';
import '../../core/ui/common.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';

class AccountSessionsScreen extends StatefulWidget {
  const AccountSessionsScreen({super.key});
  @override
  State<AccountSessionsScreen> createState() => _AccountSessionsScreenState();
}

class _AccountSessionsScreenState extends State<AccountSessionsScreen> {
  late AppState _app;
  AppUser? _owner;
  late String _origin;
  late int _revision;
  bool _initialized = false, _loading = true, _busy = false, _loaded = false;
  bool _hasMore = false;
  Failure? _failure;
  List<Map<String, dynamic>> _sessions = [];
  bool get _ar => Localizations.localeOf(context).languageCode == 'ar';
  bool get _current =>
      mounted &&
      AppUser.sameSessionOwner(_app.auth.currentUser, _owner) &&
      _app.api.baseUrl == _origin &&
      _app.api.tokens.revision == _revision;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _app = context.read<AppState>();
    _owner = _app.auth.currentUser;
    _origin = _app.api.baseUrl;
    _revision = _app.api.tokens.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current) _load();
    });
  }

  Future<void> _load() async {
    if (!_current) return;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final result = await _app.api.getObject('/auth/sessions');
      final rows = result['sessions'];
      if (rows is! List ||
          rows.any(
            (row) =>
                row is! Map ||
                row['id'] is! String ||
                row['active'] is! bool ||
                row['current'] is! bool,
          )) {
        throw const FormatException('Invalid sessions response');
      }
      if (!_current) return;
      setState(() {
        _sessions = rows
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        _hasMore = result['hasMore'] == true;
        _loaded = true;
      });
    } catch (error) {
      if (_current) {
        setState(() {
          _failure = Failure.from(error);
          _loaded = false;
        });
      }
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(Map<String, dynamic>? row) async {
    if (!_current || !_loaded || _busy) return;
    setState(() => _busy = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => Consumer<AppState>(
        builder: (_, app, _) {
          if (!_current) {
            return const AlertDialog(content: Text('Session changed'));
          }
          return AlertDialog(
            title: Text(_ar ? 'إلغاء الدخول؟' : 'Revoke access?'),
            content: Text(
              _ar
                  ? 'سيتوقف وصول ${row == null ? 'الأجهزة الأخرى' : 'هذه الجلسة'} إلى الخادم والإشعارات الجديدة عند التحقق من الجلسة. لا تُمسح بيانات الجهاز أو الرسائل التي وصلته سابقًا.'
                  : 'This ends ${row == null ? 'other sessions' : 'this session'} access to the server and new notifications when the session is checked. Stored device data and previously delivered messages are not erased.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(_ar ? 'إلغاء' : 'Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(_ar ? 'إلغاء الدخول' : 'Revoke access'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true || !_current) {
      if (_current) setState(() => _busy = false);
      return;
    }
    final isCurrent = row != null && row['current'] == true;
    try {
      final result = await _app.api.sendJson(
        method: row == null ? 'POST' : 'DELETE',
        path: row == null
            ? '/auth/sessions/revoke-others'
            : '/auth/sessions/${Uri.encodeComponent(row['id'] as String)}',
      );
      if (result['ok'] != true) {
        throw const FormatException('Unconfirmed revocation');
      }
      if (isCurrent) {
        await _app.api.tokens.clear();
        await _app.auth.signOut();
        if (mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil(
            Routes.login,
            (_) => false,
          );
        }
        return;
      }
      if (_current) await _load();
    } catch (error) {
      if (_current) {
        setState(() {
          _failure = Failure.from(error);
          _loaded = false;
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  String _stamp(Object? value) {
    final date = DateTime.tryParse(value is String ? value : '');
    if (date == null) return '—';
    final local = date.toLocal();
    final y = local.year;
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final h24 = local.hour;
    final h12 = (h24 % 12 == 0) ? 12 : h24 % 12;
    final hourStr = h12.toString().padLeft(2, '0');
    final minStr = local.minute.toString().padLeft(2, '0');
    final period = _ar ? (h24 < 12 ? 'ص' : 'م') : (h24 < 12 ? 'AM' : 'PM');
    return '$y-$m-$d $hourStr:$minStr $period';
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    if (!_current || _owner == null) {
      return const Scaffold(body: SizedBox.shrink());
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_ar ? 'جلسات الدخول' : 'Login sessions'),
        actions: [
          IconButton(
            tooltip: _ar ? 'تحديث' : 'Refresh',
            onPressed: _loading || _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ResponsiveContent(
        maxWidth: 900,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            InfoNote(
              text: _ar
                  ? 'إغلاق التطبيق لا يلغي الجلسة. عند انتهائها يلزم الدخول مجددًا. أسماء الأجهزة وصفية وليست إثباتًا لهويتها.'
                  : 'Closing the app does not revoke the session. Sign in again when it expires. Device names are descriptions, not verified device identities.',
            ),
            const SizedBox(height: 12),
            if (_failure != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(
                        _ar
                            ? 'تعذر تأكيد حالة الجلسات. حدّث القائمة قبل تنفيذ إلغاء آخر.'
                            : 'Session status could not be confirmed. Refresh before revoking again.',
                      ),
                      TextButton(
                        onPressed: _loading || _busy ? null : _load,
                        child: Text(_ar ? 'إعادة المحاولة' : 'Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_loading) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed:
                  !_loaded ||
                      _loading ||
                      _busy ||
                      !_sessions.any(
                        (row) =>
                            row['active'] == true && row['current'] != true,
                      )
                  ? null
                  : () => _revoke(null),
              icon: const Icon(Icons.phonelink_erase),
              label: Text(
                _ar ? 'إلغاء الجلسات الأخرى' : 'Revoke other sessions',
              ),
            ),
            const SizedBox(height: 12),
            if (_loaded && _sessions.isEmpty)
              Text(_ar ? 'لا توجد جلسات مسجلة.' : 'No recorded sessions.'),
            if (_hasMore)
              Text(
                _ar
                    ? 'تُعرض أحدث 100 جلسة مع جلستك الحالية.'
                    : 'Showing the latest 100 sessions including this session.',
              ),
            if (_loaded)
              for (final row in _sessions)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${row['deviceName'] ?? ''}${row['current'] == true ? (_ar ? ' · هذه الجلسة' : ' · This session') : ''}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${row['platform'] ?? ''} · ${row['active'] == true ? (_ar ? 'نشطة' : 'Active') : (_ar ? 'منتهية أو ملغاة' : 'Expired or revoked')}',
                        ),
                        Text(
                          '${_ar ? 'بدء الدخول' : 'Signed in'}: ${_stamp(row['createdAt'])}',
                        ),
                        Text(
                          '${_ar ? 'آخر استخدام' : 'Last used'}: ${_stamp(row['lastSeenAt'])}',
                        ),
                        Text(
                          '${_ar ? 'تنتهي' : 'Expires'}: ${_stamp(row['expiresAt'])}',
                        ),
                        if (row['active'] == true)
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: OutlinedButton(
                              onPressed: _busy || _loading
                                  ? null
                                  : () => _revoke(row),
                              child: Text(
                                row['current'] == true
                                    ? (_ar
                                        ? 'تسجيل الخروج من هذه الجلسة'
                                        : 'Sign out of this session')
                                    : (_ar
                                        ? 'إلغاء هذه الجلسة'
                                        : 'Revoke this session'),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
