import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/core/errors/failure.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/care_service.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';

class QueueTokens implements TokenProvider {
  @override
  String? subject = 'p';
  @override
  bool hasSession = true;
  @override
  int revision = 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class QueueApi implements ApiClient {
  @override
  final QueueTokens tokens = QueueTokens();
  @override
  String baseUrl = 'https://one.invalid';
  final calls = <String>[];
  Future<void> Function(String)? respond;
  @override
  Future<Map<String, dynamic>> sendJson({
    required String method,
    required String path,
    Map<String, Object?> body = const {},
  }) async {
    expect(body.containsKey('_ownerOrigin'), isFalse);
    expect(body.containsKey('_ownerId'), isFalse);
    calls.add(path);
    if (respond != null) await respond!(path);
    return {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class QueueDb implements LocalDatabase {
  final items = <OutboxItem>[];
  final deleted = <String>[], attempted = <String>[];
  @override
  Future<List<OutboxItem>> careOutboxForOwner(
    String ownerId, {
    String? origin,
  }) async =>
      items
          .where(
            (item) =>
                item.body['_ownerId'] == ownerId &&
                (origin == null ||
                    origin.isEmpty ||
                    item.body['_ownerOrigin'] == origin),
          )
          .toList();
  @override
  Future<List<OutboxItem>> pendingOutbox({
    int limit = 100,
    String? onlyPath,
    String? excludePath,
    String? ownerId,
  }) async => List.of(items);
  @override
  Future<void> deleteOutbox(String id) async {
    deleted.add(id);
    items.removeWhere((item) => item.id == id);
  }

  @override
  Future<void> acknowledgeCareWrite(OutboxItem item) => deleteOutbox(item.id);

  @override
  Future<void> bumpOutboxAttempt(String id, String? error) async {
    attempted.add(id);
  }

  @override
  Future<int> pendingOutboxCount() async => items.length;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

OutboxItem item(
  String id,
  String path, {
  String? origin = 'https://one.invalid',
  int attempts = 0,
}) => OutboxItem(
  id: id,
  method: 'POST',
  path: path,
  body: {'_ownerId': 'p', '_ownerOrigin': ?origin},
  createdAt: DateTime(2026),
  attempts: attempts,
);

void main() {
  test(
    'one invalid immutable report cannot block a different report identifier',
    () async {
      OutboxItem report(String id, int attempts) => OutboxItem(
        id: id,
        method: 'POST',
        path: '/patients/p/seizure-logs',
        body: {
          'id': id,
          '_ownerId': 'p',
          '_ownerOrigin': 'https://one.invalid',
        },
        createdAt: DateTime(2026),
        attempts: attempts,
      );
      final db = QueueDb()
        ..items.addAll([
          report('invalid', OutboxItem.maxAttempts),
          report('valid', 0),
        ]);
      final api = QueueApi();
      final care = CareService(api: api, db: db);
      await care.flushOutbox();
      expect(db.deleted, ['valid']);
      expect(db.items.single.id, 'invalid');
      care.dispose();
    },
  );
  test(
    'exhausted intent remains visible and blocks dependent writes only',
    () async {
      final db = QueueDb()
        ..items.addAll([
          item(
            'failed',
            '/patients/p/triggers',
            attempts: OutboxItem.maxAttempts,
          ),
          item('dependent', '/patients/p/triggers/entry'),
          item('independent', '/patients/p/seizure-logs'),
        ]);
      final api = QueueApi();
      final care = CareService(api: api, db: db);
      await care.flushOutbox();
      expect(api.calls, ['/patients/p/seizure-logs']);
      expect(care.failedOutboxCount, 1);
      expect(care.pendingCount, 1);
      expect(db.items.map((row) => row.id), ['failed', 'dependent']);
      care.dispose();
    },
  );

  test(
    'foreign held rows cannot starve current server delivery behind first batch',
    () async {
      final db = QueueDb();
      for (var i = 0; i < 150; i++) {
        db.items.add(
          item(
            'foreign-$i',
            '/patients/p/triggers',
            origin: 'https://other.invalid',
          ),
        );
      }
      db.items.add(item('current', '/patients/p/seizure-logs'));
      final api = QueueApi();
      final care = CareService(api: api, db: db);
      await care.flushOutbox();
      expect(db.deleted, ['current']);
      expect(care.heldOutboxCount, 150);
      care.dispose();
    },
  );

  test('write queued during delivery receives a follow-up flush', () async {
    final db = QueueDb()..items.add(item('first', '/patients/p/seizure-logs'));
    final gate = Completer<void>();
    final api = QueueApi()
      ..respond = (path) async {
        if (path.endsWith('seizure-logs')) await gate.future;
      };
    final care = CareService(api: api, db: db);
    final sending = care.flushOutbox();
    await Future<void>.delayed(Duration.zero);
    db.items.add(item('second', '/patients/p/triggers'));
    await care.flushOutbox();
    gate.complete();
    await sending;
    for (var i = 0; i < 20 && db.items.isNotEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(db.deleted, ['first', 'second']);
    care.dispose();
  });
  test(
    'unsupported care path does not block an independent seizure report or reorder dependent writes',
    () async {
      final db = QueueDb()
        ..items.addAll([
          item('create', '/patients/p/triggers'),
          item('update', '/patients/p/triggers/entry'),
          item('seizure', '/patients/p/seizure-logs'),
        ]);
      final api = QueueApi()
        ..respond = (path) async {
          if (path.endsWith('triggers')) {
            throw const Failure(FailureKind.notFound);
          }
        };
      await CareService(api: api, db: db).flushOutbox();
      expect(api.calls, ['/patients/p/triggers', '/patients/p/seizure-logs']);
      expect(db.deleted, ['seizure']);
      expect(db.attempted, ['create']);
      expect(db.items.map((row) => row.id), ['create', 'update']);
    },
  );
  test('unknown and foreign origins are never replayed', () async {
    final db = QueueDb()
      ..items.addAll([
        item('legacy', '/patients/p/triggers', origin: null),
        item('foreign', '/patients/p/triggers', origin: 'https://two.invalid'),
      ]);
    final api = QueueApi();
    await CareService(api: api, db: db).flushOutbox();
    expect(api.calls, isEmpty);
    expect(db.deleted, isEmpty);
    expect(db.items.length, 2);
  });
  test(
    'session change after response cannot mark the old outbox row delivered',
    () async {
      final db = QueueDb()..items.add(item('old', '/patients/p/seizure-logs'));
      final api = QueueApi();
      api.respond = (_) async {
        api.tokens.revision++;
      };
      await CareService(api: api, db: db).flushOutbox();
      expect(db.deleted, isEmpty);
      expect(db.attempted, isEmpty);
    },
  );
  test('connectivity loss stops subsequent writes', () async {
    final db = QueueDb()
      ..items.addAll([
        item('first', '/patients/p/triggers'),
        item('second', '/patients/p/seizure-logs'),
      ]);
    final api = QueueApi()
      ..respond = (_) async => throw const Failure(FailureKind.offline);
    await CareService(api: api, db: db).flushOutbox();
    expect(api.calls, ['/patients/p/triggers']);
    expect(db.deleted, isEmpty);
  });
}
