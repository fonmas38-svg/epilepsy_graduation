import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/auth_service.dart';
import 'package:epilepsy_monitor/services/care_service.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/sync_service.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';

class MemoryStore implements LocalDatabase {
  final pending = <OutboxItem>[];
  AlertItem? saved;
  @override
  Future<void> insertAlert(AlertItem alert, {OutboxItem? delivery}) async {
    saved = alert;
    if (delivery != null) pending.add(delivery);
  }

  @override
  Future<List<OutboxItem>> pendingOutbox({
    int limit = 100,
    String? onlyPath,
    String? excludePath,
    String? ownerId,
  }) async => List.of(pending);
  @override
  Future<void> deleteOutbox(String id) async =>
      pending.removeWhere((item) => item.id == id);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SessionTokens implements TokenProvider {
  @override
  bool get hasSession => true;
  @override
  String? get subject => 'p1';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DeliveryApi implements ApiClient {
  bool fail = true;
  final sent = <Map<String, Object?>>[];
  @override
  final TokenProvider tokens = SessionTokens();
  @override
  Future<Map<String, dynamic>> sendJson({
    required String method,
    required String path,
    Map<String, Object?> body = const {},
  }) async {
    if (fail) throw Exception('network unavailable');
    sent.add(body);
    return {'ok': true};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'care outbox does not replay a different account or unowned legacy write',
    () async {
      final db = MemoryStore();
      final api = DeliveryApi()..fail = false;
      for (final owner in ['p1', 'p2', null]) {
        db.pending.add(
          OutboxItem(
            id: '$owner',
            method: 'POST',
            path: '/patients/p1/triggers',
            body: {'_ownerId': owner},
            createdAt: DateTime.now(),
          ),
        );
      }
      final care = CareService(api: api, db: db);
      await care.flushOutbox();
      expect(api.sent, hasLength(1));
      expect(api.sent.single.containsKey('_ownerId'), isFalse);
      expect(db.pending.map((item) => item.id), containsAll(['p2', 'null']));
    },
  );
  test(
    'SOS survives failure, remains owned by sender, then retries with same id',
    () async {
      final db = MemoryStore();
      final api = DeliveryApi();
      final auth = AuthService()
        ..currentUser = AppUser(
          uid: 'p1',
          name: 'Patient',
          email: '',
          role: UserRole.patient,
        );
      final sync = SyncService(db: db, api: api, auth: auth);
      final alert = await sync.sendSos('p1');
      expect(db.saved?.id, alert.id);
      expect(db.pending, hasLength(1));
      api.fail = false;
      auth.currentUser = AppUser(
        uid: 'p2',
        name: 'Other',
        email: '',
        role: UserRole.patient,
      );
      await sync.flushPendingAlerts();
      expect(api.sent, isEmpty);
      expect(db.pending, hasLength(1));
      auth.currentUser = AppUser(
        uid: 'p1',
        name: 'Patient',
        email: '',
        role: UserRole.patient,
      );
      await sync.flushPendingAlerts();
      expect(db.pending, isEmpty);
      expect((api.sent.single['alert'] as Map)['id'], alert.id);
      expect(api.sent.single.containsKey('_ownerId'), isFalse);
      await sync.flushPendingAlerts();
      expect(api.sent, hasLength(1));
    },
  );
}
