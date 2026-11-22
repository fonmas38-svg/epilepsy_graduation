import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/enums.dart';
import '../../core/errors/failure.dart';
import '../../core/ui/common.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../widgets/care_sync_status_card.dart';

class PrivacyRequestsScreen extends StatefulWidget {
  const PrivacyRequestsScreen({super.key});
  @override
  State<PrivacyRequestsScreen> createState() => _PrivacyRequestsScreenState();
}

class _PrivacyRequestsScreenState extends State<PrivacyRequestsScreen> {
  late final AppState _app;
  late final AppUser? _owner;
  late final String _origin;
  late final int _revision;
  bool _loading = true,
      _busy = false,
      _loaded = false,
      _queued = false,
      _more = false;
  Failure? _failure;
  List<Map<String, dynamic>> _rows = [];
  bool get _ar => Localizations.localeOf(context).languageCode == 'ar';
  bool get _admin => _owner?.role == UserRole.admin;
  bool get _current =>
      mounted &&
      {UserRole.patient, UserRole.admin}.contains(_owner?.role) &&
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
      if (_current) _load();
    });
  }

  Future<void> _load() async {
    if (!_current || _owner == null) return;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final body = await _app.api.getObject(
        _admin
            ? '/admin/deletion-requests'
            : '/patients/${_owner.uid}/deletion-requests',
      );
      final rows = body['requests'];
      if (rows is! List ||
          rows.any(
            (row) =>
                row is! Map ||
                row['id'] is! String ||
                row['patientId'] is! String ||
                row['status'] is! String,
          )) {
        throw const FormatException('Invalid privacy requests');
      }
      if (!_current) return;
      setState(() {
        _rows = rows
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        _loaded = true;
        _more = body['hasMore'] == true;
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

  Future<void> _request() async {
    if (!_current || _busy || _owner?.role != UserRole.patient) return;
    setState(() => _busy = true);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(_ar ? 'طلب حذف الحساب؟' : 'Request account erasure?'),
        content: Text(
          _ar
              ? 'سيُحفظ طلبك ويُرسل للإدارة عند الاتصال. يتطلب التحقق من الهوية ومراجعة البيانات التي يمكن محوها؛ لن تُحذف بياناتك أو تتوقف المراقبة بمجرد تقديمه.'
              : 'Your request will be saved and sent to the administrator when connected. Identity verification and retention review are required; submitting it does not erase data or stop monitoring.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(_ar ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(_ar ? 'تقديم الطلب' : 'Submit request'),
          ),
        ],
      ),
    );
    if (ok != true || !_current) {
      if (_current) setState(() => _busy = false);
      return;
    }
    try {
      if (_app.care.patientId != _owner!.uid) {
        await _app.care.loadFor(_owner.uid, remote: false);
      }
      if (!_current) return;
      await _app.care.requestAccountDeletion();
      if (_current) setState(() => _queued = true);
    } catch (error) {
      if (_current) setState(() => _failure = Failure.from(error));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _review(Map<String, dynamic> row) async {
    if (!_current || !_admin || _busy) return;
    setState(() => _busy = true);
    await showDialog<bool>(
      context: context,
      builder: (_) => PrivacyReviewDialog(
        current: () => _current,
        save: (status, note) async {
          if (!_current) throw StateError('Session changed');
          final body = await _app.api.sendJson(
            method: 'POST',
            path:
                '/admin/deletion-requests/${row['patientId']}/${row['id']}/review',
            body: {
              'status': status,
              'note': note,
              'expected_version': row['reviewVersion'],
            },
          );
          if (!_current) throw StateError('Session changed');
          if (body['request'] is! Map) {
            throw const FormatException('Unconfirmed review');
          }
        },
      ),
    );
    if (_current) {
      setState(() => _busy = false);
      await _load();
    }
  }

  String _status(String value) => switch (value) {
    'received' => _ar ? 'استلمه الخادم' : 'Received by server',
    'under_review' => _ar ? 'قيد مراجعة الإدارة' : 'Under administrator review',
    'rejected' =>
      _ar ? 'يتعذر تنفيذه؛ راجع السبب' : 'Cannot proceed; see the reason',
    _ => _ar ? 'حالة غير معروفة' : 'Unknown status',
  };

  String _stamp(Object? value) {
    final at = DateTime.tryParse(value is String ? value : '');
    return at == null ? '—' : at.toLocal().toString().split('.').first;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    if (!_current ||
        !{UserRole.patient, UserRole.admin}.contains(_owner?.role)) {
      return const Scaffold(body: SizedBox.shrink());
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_ar ? 'طلبات حذف الحساب' : 'Account erasure requests'),
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
                  ? 'هذه متابعة طلب ومراجعة. تغيير حالته لا ينفذ محوًا آليًا للبيانات.'
                  : 'This tracks request receipt and review. Changing status does not automatically erase data.',
            ),
            if (!_admin) ...[
              const SizedBox(height: 12),
              const CareSyncStatusCard(),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed:
                    _busy ||
                        _queued ||
                        (_loaded &&
                            _rows.any((row) => row['status'] != 'rejected'))
                    ? null
                    : _request,
                icon: const Icon(Icons.person_remove_outlined),
                label: Text(_ar ? 'تقديم طلب' : 'Submit a request'),
              ),
            ],
            if (_queued)
              Text(
                _ar
                    ? 'حُفظ طلبك محليًا. حدّث القائمة بعد إرساله لتأكيد استلام الخادم.'
                    : 'Saved locally. Refresh after delivery to confirm server receipt.',
              ),
            if (_loading) const LinearProgressIndicator(),
            if (_failure != null)
              Semantics(
                liveRegion: true,
                child: Column(
                  children: [
                    Text(
                      _ar
                          ? 'تعذر تحميل الحالة أو حفظ الطلب. البيانات السابقة محفوظة.'
                          : 'Could not load status or save the request. Existing data was retained.',
                    ),
                    TextButton(
                      onPressed: _busy || _loading ? null : _load,
                      child: Text(_ar ? 'إعادة المحاولة' : 'Retry'),
                    ),
                  ],
                ),
              ),
            if (_loaded && _rows.isEmpty)
              Text(
                _ar
                    ? 'لا توجد طلبات مستلمة على الخادم.'
                    : 'No requests received by the server.',
              ),
            if (_more)
              Text(
                _ar
                    ? 'تُعرض أحدث 100 طلب.'
                    : 'Showing the latest 100 requests.',
              ),
            if (_loaded)
              for (final row in _rows)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_admin)
                          Text(
                            row['patientName'] as String? ??
                                row['patientId'] as String,
                          ),
                        Text(
                          _status(row['status'] as String),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(_stamp(row['recordedAt'])),
                        if ((row['reason'] as String? ?? '').isNotEmpty)
                          Text(row['reason'] as String),
                        if ((row['reviewNote'] as String? ?? '').isNotEmpty)
                          Text(row['reviewNote'] as String),
                        if (_admin)
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: OutlinedButton(
                              onPressed: _busy ? null : () => _review(row),
                              child: Text(
                                _ar ? 'مراجعة الطلب' : 'Review request',
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

class PrivacyReviewDialog extends StatefulWidget {
  const PrivacyReviewDialog({
    super.key,
    required this.current,
    required this.save,
  });
  final bool Function() current;
  final Future<void> Function(String status, String note) save;
  @override
  State<PrivacyReviewDialog> createState() => _PrivacyReviewDialogState();
}

class _PrivacyReviewDialogState extends State<PrivacyReviewDialog> {
  final _form = GlobalKey<FormState>();
  final _note = TextEditingController();
  String _status = 'under_review';
  bool _busy = false, _uncertain = false;
  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy ||
        _uncertain ||
        !widget.current() ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.save(_status, _note.text.trim());
      if (mounted && widget.current()) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _uncertain = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    if (!widget.current()) {
      return const AlertDialog(content: Text('Session changed'));
    }
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(ar ? 'مراجعة طلب الحذف' : 'Review erasure request'),
        content: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(
                      value: 'under_review',
                      child: Text(ar ? 'قيد المراجعة' : 'Under review'),
                    ),
                    DropdownMenuItem(
                      value: 'rejected',
                      child: Text(ar ? 'يتعذر التنفيذ' : 'Cannot proceed'),
                    ),
                  ],
                  onChanged: _busy || _uncertain
                      ? null
                      : (value) => setState(() => _status = value!),
                ),
                TextFormField(
                  controller: _note,
                  readOnly: _busy || _uncertain,
                  maxLength: 2000,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: ar ? 'ملاحظة للمريض' : 'Note to patient',
                  ),
                  validator: (value) =>
                      _status == 'rejected' && (value ?? '').trim().isEmpty
                      ? (ar ? 'اذكر السبب للمريض' : 'Give the patient a reason')
                      : null,
                ),
                if (_uncertain)
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      ar
                          ? 'لم تتأكد النتيجة. الملاحظة محفوظة هنا؛ أغلق وحدّث حالة الطلب قبل تغيير القرار.'
                          : 'The result is unconfirmed. Your note remains here; close and refresh request status before changing the decision.',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(ar ? 'إغلاق' : 'Close'),
          ),
          FilledButton(
            onPressed: _busy || _uncertain ? null : _save,
            child: Text(ar ? 'حفظ المراجعة' : 'Save review'),
          ),
        ],
      ),
    );
  }
}
