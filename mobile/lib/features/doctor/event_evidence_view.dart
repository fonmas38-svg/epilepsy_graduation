import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/time_ago.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/app_state.dart';
import '../../widgets/signal_chart.dart';

/// Displays retained measurements, without synthesizing missing event data.
class EventEvidenceView extends StatefulWidget {
  const EventEvidenceView({
    super.key,
    required this.patientId,
    required this.alertId,
  });
  final String patientId;
  final String alertId;

  @override
  State<EventEvidenceView> createState() => _EventEvidenceViewState();
}

class _EventEvidenceViewState extends State<EventEvidenceView> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _failed = false;
  int _selected = 0;
  int _request = 0;
  AppUser? _owner;
  String? _origin;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _owner = app.auth.currentUser;
    _origin = app.api.baseUrl;
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final request = ++_request;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final data = await app.api.sendJson(
        method: 'GET',
        path:
            '/patients/${Uri.encodeComponent(widget.patientId)}/alerts/${Uri.encodeComponent(widget.alertId)}/evidence',
      );
      if (!mounted ||
          request != _request ||
          !AppUser.sameSessionOwner(_owner, app.auth.currentUser) ||
          _origin != app.api.baseUrl) {
        return;
      }
      setState(() {
        _data = data;
        _selected = 0;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!AppUser.sameSessionOwner(_owner, app.auth.currentUser) ||
        _origin != app.api.baseUrl) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    if (_loading) return const LinearProgressIndicator();
    if (_failed) {
      return TextButton.icon(
        onPressed: _load,
        icon: const Icon(Icons.refresh),
        label: Text(
          l.isArabic
              ? 'تعذر تحميل إشارات الحدث؛ إعادة المحاولة'
              : 'Event signals unavailable; retry',
        ),
      );
    }
    final rows = (_data?['readings'] as List? ?? []).whereType<Map>().toList();
    if (rows.isEmpty) {
      return Text(
        l.isArabic
            ? 'لا توجد إشارات محفوظة خلال 10 ثوانٍ قبل الحدث وبعده.'
            : 'No retained signals within 10 seconds before or after this event.',
      );
    }
    final row = rows[_selected];
    List<double> signal(String key) => (row[key] as List? ?? [])
        .whereType<num>()
        .map((v) => v.toDouble())
        .where((v) => v.isFinite)
        .toList();
    String stamp(Map row) {
      final time = DateTime.tryParse(row['timestamp']?.toString() ?? '');
      return time == null ? l.notSet : TimeAgo.stamp(time.toLocal(), l);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.isArabic ? 'الإشارات المحفوظة حول الحدث' : 'Retained event signals',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Text(
          l.isArabic
              ? 'قد تكون التغطية جزئية. المحور الأفقي يمثل العينات؛ الوحدات غير موثقة.'
              : 'Coverage may be partial. The horizontal axis shows samples; units are undocumented.',
        ),
        DropdownButton<int>(
          value: _selected,
          isExpanded: true,
          items: [
            for (var i = 0; i < rows.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text('${i + 1} · ${stamp(rows[i])}'),
              ),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _selected = v);
          },
        ),
        for (final channel in ['eeg', 'ecg', 'motion'])
          InteractiveViewer(
            minScale: 1,
            maxScale: 6,
            child: SignalChart(
              title: channel.toUpperCase(),
              values: signal(channel),
            ),
          ),
        Text(
          'HR: ${row['hr'] is num && (row['hr'] as num).isFinite ? row['hr'] : l.notSet}',
        ),
        if (_data?['truncated'] == true)
          Text(
            l.isArabic
                ? 'عرض أول 64 نافذة؛ توجد بيانات إضافية.'
                : 'Showing the first 64 windows; more data exists.',
          ),
      ],
    );
  }
}
