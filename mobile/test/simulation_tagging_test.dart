import 'package:epilepsy_monitor/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'offline_sync_policy_test.dart' show Store, Cloud, Session, reading;
import 'package:epilepsy_monitor/services/sync_service.dart';

class _Sync extends SyncService {
  _Sync(Store s, Cloud c, Session a) : super(db: s, api: c, auth: a);
}

AlertItem _alert(Map<String, dynamic> details) => AlertItem(
  id: 'a1',
  patientId: 'p1',
  timestamp: DateTime(2026, 11, 25),
  severity: 'critical',
  message: 'نوبة محتملة',
  recipients: const ['doctor'],
  details: details,
);

void main() {
  test('simulated alerts are prefixed, clinical ones are not', () {
    expect(
      _alert({'data_source': 'simulation'}).displayMessage,
      '[محاكاة] نوبة محتملة',
    );
    expect(_alert({'data_source': 'dataset'}).isSimulated, isTrue);
    expect(_alert({'data_source': 'device'}).displayMessage, 'نوبة محتملة');
    expect(_alert({}).isSimulated, isFalse);
  });

  test('tag survives the JSON round trip used by the cloud sync', () {
    final back = AlertItem.fromMap(
      _alert({'data_source': 'simulation'}).toMap(),
    );
    expect(back.isSimulated, isTrue);
  });

  test('assessments are stamped with the current data source', () async {
    final sync = _Sync(Store(), Cloud(), Session())
      ..dataSourceOf = () => 'simulation';
    final a = await sync.analyzeAndStore(reading());
    expect(a.features['data_source'], 'simulation');
    expect(a.isSimulated, isTrue);

    final real = _Sync(Store(), Cloud(), Session())
      ..dataSourceOf = () => 'device';
    final b = await real.analyzeAndStore(reading());
    expect(b.isSimulated, isFalse);
  });

  test('SOS never promises a location that cannot come', () async {
    final store = Store();
    final sync = _Sync(store, Cloud(), Session());
    final pending = await sync.sendSos('p1', patientName: 'م');
    final none = await sync.sendSos(
      'p1',
      patientName: 'م',
      locationExpected: false,
    );
    expect(pending.message, isNot(equals(none.message)));
    expect(none.message, contains('غير متوفر'));
  });
}
