import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

OutboxItem delivery(
  String id, {
  String patient = 'patient',
  String table = 'emergency_contacts',
  String rowId = 'contact',
  int attempts = 0,
  String name = 'Family',
}) => OutboxItem(
  id: id,
  method: 'PUT',
  path: '/patients/$patient/emergency-contacts/$rowId',
  body: {
    'name': name,
    '_ownerId': 'owner',
    '_ownerOrigin': 'https://one.invalid',
    '_table': table,
    '_rowId': rowId,
  },
  createdAt: DateTime.utc(2026, 11, 14),
  attempts: attempts,
);

Map<String, Object?> contact({String name = 'Family'}) => {
  'id': 'contact',
  'patientId': 'patient',
  'name': name,
  'phone': '123',
};

void main() {
  late Database sql;
  late LocalDatabase store;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalDatabase.createTestSchema(sql);
    store = LocalDatabase.forDatabase(sql);
  });
  tearDown(() async => sql.close());

  test(
    'clinical contract migration preserves v7 rows and is idempotent',
    () async {
      final legacy = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        await legacy.execute(
          'CREATE TABLE messages (id TEXT PRIMARY KEY, content TEXT)',
        );
        await legacy.execute(
          "INSERT INTO messages VALUES ('pending', 'Keep me')",
        );
        await legacy.execute(
          'CREATE TABLE medications (id TEXT PRIMARY KEY, name TEXT)',
        );
        await legacy.execute(
          "INSERT INTO medications VALUES ('old-rx', 'Existing medicine')",
        );
        await legacy.execute(
          'CREATE TABLE medication_logs (id TEXT PRIMARY KEY, status TEXT)',
        );
        await migrateClinicalContracts(legacy);
        await migrateClinicalContracts(legacy);
        expect((await legacy.query('messages')).single['content'], 'Keep me');
        expect(
          (await legacy.query('medications')).single['name'],
          'Existing medicine',
        );
        final columns = await legacy.rawQuery('PRAGMA table_info(messages)');
        expect(
          columns.map((r) => r['name']),
          containsAll(['peerUserId', 'deliveredAt']),
        );
      } finally {
        await legacy.close();
      }
    },
  );

  test(
    'explicit retry preserves payload and never resets another source',
    () async {
      final own = delivery('own', attempts: OutboxItem.maxAttempts);
      final foreign = OutboxItem(
        id: 'foreign',
        method: own.method,
        path: own.path,
        body: {...own.body, '_ownerOrigin': 'https://other.invalid'},
        createdAt: own.createdAt,
        attempts: OutboxItem.maxAttempts,
      );
      await store.enqueueOutbox(own);
      await store.enqueueOutbox(foreign);
      expect((await store.careOutboxForOwner('owner')).length, 2);
      expect(
        await store.retryCareWrites(
          ownerId: 'owner',
          origin: 'https://one.invalid',
        ),
        1,
      );
      final rows = await store.careOutboxForOwner('owner');
      expect(rows.first.id, own.id);
      expect(rows.first.body, own.body);
      expect(rows.first.createdAt, own.createdAt);
      expect(rows.first.attempts, 0);
      expect(rows.last.attempts, OutboxItem.maxAttempts);
      expect(await store.careOutboxForOwner('different-owner'), isEmpty);
    },
  );

  test('care row and delivery commit together with an unsynced row', () async {
    await store.persistCareWrite(
      item: delivery('write'),
      table: 'emergency_contacts',
      row: {...contact(), 'synced': 1},
    );
    expect(
      (await store.emergencyContactsFor('patient')).single.synced,
      isFalse,
    );
    expect((await store.pendingOutbox()).single.id, 'write');
  });

  test('failed outbox insert rolls back a local edit', () async {
    await sql.insert('emergency_contacts', {...contact(), 'synced': 1});
    await store.enqueueOutbox(delivery('duplicate'));
    await expectLater(
      store.persistCareWrite(
        item: delivery('duplicate', name: 'Changed'),
        table: 'emergency_contacts',
        row: contact(name: 'Changed'),
      ),
      throwsA(isA<DatabaseException>()),
    );
    final existing = (await store.emergencyContactsFor('patient')).single;
    expect(existing.name, 'Family');
    expect(existing.synced, isTrue);
    expect((await store.pendingOutbox()).single.body['name'], 'Family');
  });

  test('failed outbox insert also rolls back a local deletion', () async {
    await sql.insert('emergency_contacts', contact());
    await store.enqueueOutbox(delivery('duplicate'));
    await expectLater(
      store.persistCareWrite(
        item: delivery('duplicate'),
        table: 'emergency_contacts',
        deleteId: 'contact',
        patientId: 'patient',
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect(await store.emergencyContactsFor('patient'), hasLength(1));
  });

  test('deletion requires and respects the patient scope', () async {
    await sql.insert('emergency_contacts', contact());
    await expectLater(
      store.persistCareWrite(
        item: delivery('no-patient'),
        table: 'emergency_contacts',
        deleteId: 'contact',
      ),
      throwsArgumentError,
    );
    await store.persistCareWrite(
      item: delivery('other', patient: 'other'),
      table: 'emergency_contacts',
      deleteId: 'contact',
      patientId: 'other',
    );
    expect(await store.emergencyContactsFor('patient'), hasLength(1));
    await store.persistCareWrite(
      item: delivery('remove'),
      table: 'emergency_contacts',
      deleteId: 'contact',
      patientId: 'patient',
    );
    expect(await store.emergencyContactsFor('patient'), isEmpty);
    expect((await store.pendingOutbox()).map((row) => row.id), [
      'other',
      'remove',
    ]);
  });

  test('older acknowledgment cannot sync a newer exhausted edit', () async {
    final first = delivery('first');
    final newer = delivery(
      'newer',
      name: 'New family',
      attempts: OutboxItem.maxAttempts,
    );
    await store.persistCareWrite(item: first, row: contact());
    await store.persistCareWrite(
      item: newer,
      row: contact(name: 'New family'),
    );
    await store.acknowledgeCareWrite(first);
    final row = (await store.emergencyContactsFor('patient')).single;
    expect(row.name, 'New family');
    expect(row.synced, isFalse);
    expect((await sql.query('outbox')).single['id'], 'newer');
    await store.acknowledgeCareWrite(newer);
    expect((await store.emergencyContactsFor('patient')).single.synced, isTrue);
    expect(await sql.query('outbox'), isEmpty);
  });

  test('medical card acknowledgment uses its patient primary key', () async {
    final item = delivery('card', table: 'medical_card', rowId: 'patient');
    await store.persistCareWrite(
      item: item,
      row: {'patientId': 'patient', 'updatedAt': '2026-11-14T10:00:00Z'},
    );
    await store.acknowledgeCareWrite(item);
    expect((await store.medicalCardFor('patient'))!.synced, isTrue);
  });

  test('invalid table or patient metadata never mutates care rows', () async {
    await expectLater(
      store.persistCareWrite(item: delivery('unsafe', table: 'users')),
      throwsArgumentError,
    );
    await expectLater(
      store.persistCareWrite(
        item: delivery('wrong-patient', patient: 'other'),
        row: contact(),
      ),
      throwsArgumentError,
    );
    await sql.insert('emergency_contacts', contact());
    await expectLater(
      store.persistCareWrite(
        item: delivery('collision', patient: 'other'),
        row: {...contact(), 'patientId': 'other'},
      ),
      throwsStateError,
    );
    expect(await sql.query('outbox'), isEmpty);
    expect(await store.emergencyContactsFor('patient'), hasLength(1));
  });

  test(
    'changed delivery cannot acknowledge a different queued payload',
    () async {
      await store.persistCareWrite(item: delivery('same'), row: contact());
      await expectLater(
        store.acknowledgeCareWrite(delivery('same', name: 'Unaccepted')),
        throwsStateError,
      );
      expect(await sql.query('outbox'), hasLength(1));
      expect(
        (await store.emergencyContactsFor('patient')).single.synced,
        isFalse,
      );
    },
  );

  test(
    'pending deletion protection includes exhausted writes in this scope',
    () async {
      for (final scope in [
        ('active', 'patient', 'owner', 'https://one.invalid', 0, 'DELETE'),
        ('exhausted', 'patient', 'owner', 'https://one.invalid', 8, 'DELETE'),
        ('other-owner', 'patient', 'other', 'https://one.invalid', 0, 'DELETE'),
        (
          'other-origin',
          'patient',
          'owner',
          'https://two.invalid',
          0,
          'DELETE',
        ),
        (
          'other-patient',
          'patient2',
          'owner',
          'https://one.invalid',
          0,
          'DELETE',
        ),
        ('not-deleted', 'patient', 'owner', 'https://one.invalid', 0, 'PUT'),
      ]) {
        await store.enqueueOutbox(
          OutboxItem(
            id: scope.$1,
            method: scope.$6,
            path: '/patients/${scope.$2}/triggers/${scope.$1}',
            body: {'_ownerId': scope.$3, '_ownerOrigin': scope.$4},
            attempts: scope.$5,
            createdAt: DateTime.utc(2026, 11, 14),
          ),
        );
      }
      expect(
        await store.queuedCareDeletes(
          patientId: 'patient',
          ownerId: 'owner',
          origin: 'https://one.invalid',
        ),
        {
          '/patients/patient/triggers/active',
          '/patients/patient/triggers/exhausted',
        },
      );
    },
  );

  test(
    'remote deletions remove only synced rows in the patient scope',
    () async {
      final ids = <String>[];
      await sql.transaction((txn) async {
        for (var index = 0; index < 225; index++) {
          final id = 'synced-$index';
          ids.add(id);
          await txn.insert('emergency_contacts', {
            ...contact(),
            'id': id,
            'synced': 1,
          });
        }
        await txn.insert('emergency_contacts', {
          ...contact(),
          'id': 'unsent',
          'synced': 0,
        });
        await txn.insert('emergency_contacts', {
          ...contact(),
          'id': 'foreign',
          'patientId': 'another',
          'synced': 1,
        });
      });
      await store.removeSyncedCareRows(
        table: 'emergency_contacts',
        patientId: 'patient',
        ids: [...ids, 'unsent', 'foreign'],
      );
      expect((await store.emergencyContactsFor('patient')).single.id, 'unsent');
      expect(
        (await store.emergencyContactsFor('another')).single.id,
        'foreign',
      );
      await expectLater(
        store.removeSyncedCareRows(
          table: 'medical_card',
          patientId: 'patient',
          ids: ['patient'],
        ),
        throwsArgumentError,
      );
    },
  );
}
