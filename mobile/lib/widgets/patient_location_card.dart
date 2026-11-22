import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/ui/common.dart';
import '../core/utils/external_actions.dart';
import '../core/utils/time_ago.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../providers/app_state.dart';

/// Every location is explicitly bound to a patient and timestamp, never "live".
class PatientLocationCard extends StatefulWidget {
  const PatientLocationCard({
    super.key,
    required this.patientId,
    required this.patientName,
  });
  final String patientId;
  final String patientName;
  @override
  State<PatientLocationCard> createState() => _PatientLocationCardState();
}

class _PatientLocationCardState extends State<PatientLocationCard> {
  Future<Map<String, dynamic>?>? _location;
  AppUser? _owner;
  String? _origin;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppState>();
    if (_location == null ||
        !AppUser.sameSessionOwner(_owner, app.auth.currentUser) ||
        _origin != app.api.baseUrl) {
      _owner = app.auth.currentUser;
      _origin = app.api.baseUrl;
      _location = app.messages.fetchLatestLocation(widget.patientId);
    }
  }

  @override
  void didUpdateWidget(covariant PatientLocationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.patientId != widget.patientId) {
      _location = context.read<AppState>().messages.fetchLatestLocation(
        widget.patientId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final ar = AppLocalizations.of(context).isArabic;
    return SectionCard(
      title: ar
          ? 'آخر موقع: ${widget.patientName}'
          : 'Last location: ${widget.patientName}',
      icon: Icons.location_on_outlined,
      child: FutureBuilder<Map<String, dynamic>?>(
        future: _location,
        builder: (context, snapshot) {
          if (!app.messages.canAccess(widget.patientId)) {
            return Text(
              ar
                  ? 'الموقع غير متاح لهذا الحساب'
                  : 'Location is unavailable for this account',
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LinearProgressIndicator();
          }
          final data = snapshot.data;
          final lat = double.tryParse('${data?['latitude']}');
          final lon = double.tryParse('${data?['longitude']}');
          final accuracy = double.tryParse('${data?['accuracy']}');
          final valid =
              lat != null &&
              lon != null &&
              lat.isFinite &&
              lon.isFinite &&
              lat.abs() <= 90 &&
              lon.abs() <= 180;
          final at = DateTime.tryParse('${data?['updatedAt']}');
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                ar
                    ? 'هذه آخر مشاركة محفوظة وليست تتبعًا حيًا.'
                    : 'This is the last saved share, not live tracking.',
              ),
              const SizedBox(height: 8),
              if (valid) ...[
                SelectableText(
                  '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}',
                  textDirection: TextDirection.ltr,
                ),
                Text(
                  at == null
                      ? (ar ? 'وقت المشاركة غير معروف' : 'Share time unknown')
                      : TimeAgo.stamp(at),
                ),
                if (accuracy != null && accuracy.isFinite && accuracy >= 0)
                  Text(
                    ar
                        ? 'دقة تقريبية: ${accuracy.round()} متر'
                        : 'Approximate accuracy: ${accuracy.round()} m',
                  ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final opened = await ExternalActions.showOnMap(
                      latitude: lat,
                      longitude: lon,
                    );
                    if (!opened && context.mounted) {
                      AppSnack.warn(
                        context,
                        ar
                            ? 'تعذر فتح الخرائط. يمكنك نسخ الإحداثيات المعروضة.'
                            : 'Unable to open maps. Copy the coordinates shown above.',
                      );
                    }
                  },
                  icon: const Icon(Icons.map_outlined),
                  label: Text(ar ? 'فتح الخريطة' : 'Open map'),
                ),
              ] else
                Text(
                  ar
                      ? 'لا يوجد موقع صالح متاح. قد يكون غير مشترك أو تعذر جلبه.'
                      : 'No valid location is available. It may not be shared or could not be retrieved.',
                ),
              TextButton(
                onPressed: () => setState(
                  () => _location = app.messages.fetchLatestLocation(
                    widget.patientId,
                  ),
                ),
                child: Text(
                  ar ? 'تحديث الموقع المشترك' : 'Refresh shared location',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
