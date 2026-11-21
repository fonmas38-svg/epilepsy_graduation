import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/models/message_model.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/care_service.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';

class _TestTokens implements TokenProvider {
  @override
  String? subject = 'user_1';
  @override
  bool hasSession = true;
  @override
  int revision = 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeApi extends ApiClient {
  _FakeApi({required String origin, required String subject})
    : super(baseUrl: origin, tokens: _TestTokens()..subject = subject);

  Map<String, dynamic> remoteCard = {};
  bool online = true;

  @override
  Future<Map<String, dynamic>> getObject(String path) async {
    if (path.contains('/medical-card')) {
      return remoteCard;
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(String path) async => [];

  @override
  Future<Map<String, dynamic>> sendJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    if (!online) throw Exception('Offline: cannot flush');
    return {};
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('Phase 1: Local SQLite Storage Origin Isolation & Migration', () {
    test('Additive migration from v5 to v6 preserves all legacy data as serverOrigin = empty', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);

      // 1. Create a legacy v5 schema without serverOrigin
      await db.execute('''
        CREATE TABLE emergency_contacts (
          id TEXT PRIMARY KEY,
          patientId TEXT NOT NULL,
          name TEXT NOT NULL,
          phone TEXT NOT NULL,
          relation TEXT NOT NULL DEFAULT '',
          priority INTEGER NOT NULL DEFAULT 0,
          notes TEXT NOT NULL DEFAULT '',
          synced INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE medical_card (
          patientId TEXT PRIMARY KEY,
          diagnosis TEXT NOT NULL DEFAULT '',
          allergies TEXT NOT NULL DEFAULT '',
          bloodType TEXT NOT NULL DEFAULT '',
          doctorName TEXT NOT NULL DEFAULT '',
          doctorPhone TEXT NOT NULL DEFAULT '',
          notes TEXT NOT NULL DEFAULT '',
          updatedAt TEXT NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE trigger_entries (
          id TEXT PRIMARY KEY,
          patientId TEXT NOT NULL,
          occurredAt TEXT NOT NULL,
          kind TEXT NOT NULL,
          intensity INTEGER NOT NULL DEFAULT 3,
          note TEXT NOT NULL DEFAULT '',
          synced INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE seizure_logs (
          id TEXT PRIMARY KEY,
          patientId TEXT NOT NULL,
          occurredAt TEXT NOT NULL,
          durationSeconds INTEGER,
          type TEXT NOT NULL DEFAULT 'other',
          notes TEXT NOT NULL DEFAULT '',
          reportedBy TEXT NOT NULL DEFAULT '',
          alertId TEXT,
          synced INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE messages (
          id TEXT PRIMARY KEY,
          patientId TEXT NOT NULL,
          senderId TEXT NOT NULL,
          senderName TEXT NOT NULL,
          senderRole TEXT NOT NULL,
          channelType TEXT NOT NULL,
          content TEXT NOT NULL,
          sentAt TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'sending',
          clientMessageId TEXT NOT NULL DEFAULT ''
        )
      ''');

      // 2. Insert legacy rows before migration
      await db.insert('emergency_contacts', {
        'id': 'contact_legacy_1',
        'patientId': 'pat_1',
        'name': 'Legacy Mom',
        'phone': '123456789',
        'priority': 0,
        'synced': 1,
      });
      await db.insert('medical_card', {
        'patientId': 'pat_1',
        'diagnosis': 'Refractory Epilepsy',
        'allergies': 'Penicillin',
        'bloodType': 'O+',
        'updatedAt': '2026-01-01T00:00:00Z',
        'synced': 1,
      });
      await db.insert('trigger_entries', {
        'id': 'trig_legacy_1',
        'patientId': 'pat_1',
        'occurredAt': '2026-01-01T12:00:00Z',
        'kind': 'stress',
        'intensity': 4,
        'synced': 1,
      });

      // 3. Execute migration
      await migrateOriginIsolation(db);

      // 4. Verify all legacy data is preserved with serverOrigin = ''
      final store = LocalDatabase.forDatabase(db);
      final legacyContacts = await store.emergencyContactsFor('pat_1');
      expect(legacyContacts, hasLength(1));
      expect(legacyContacts.first.name, 'Legacy Mom');
      expect(legacyContacts.first.serverOrigin, '');

      final legacyCard = await store.medicalCardFor('pat_1');
      expect(legacyCard, isNotNull);
      expect(legacyCard!.diagnosis, 'Refractory Epilepsy');
      expect(legacyCard.serverOrigin, '');

      final legacyTriggers = await store.triggersFor('pat_1');
      expect(legacyTriggers, hasLength(1));
      expect(legacyTriggers.first.kind, TriggerKind.stress);
      expect(legacyTriggers.first.serverOrigin, '');

      // 5. Verify composite primary key allows same patientId with distinct serverOrigin
      await store.upsertMedicalCard(
        MedicalCard(
          patientId: 'pat_1',
          serverOrigin: 'https://server-a.invalid',
          diagnosis: 'Server A Diagnosis',
          updatedAt: DateTime.utc(2026, 2, 1),
        ),
      );
      await store.upsertMedicalCard(
        MedicalCard(
          patientId: 'pat_1',
          serverOrigin: 'https://server-b.invalid',
          diagnosis: 'Server B Diagnosis',
          updatedAt: DateTime.utc(2026, 2, 2),
        ),
      );

      final cardA = await store.medicalCardFor('pat_1', serverOrigin: 'https://server-a.invalid');
      final cardB = await store.medicalCardFor('pat_1', serverOrigin: 'https://server-b.invalid');
      expect(cardA?.diagnosis, 'Server A Diagnosis');
      expect(cardB?.diagnosis, 'Server B Diagnosis');

      await db.close();
    });

    test('Isolated queries prevent cross-server collisions and leakage', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalDatabase.createTestSchema(db);
      final store = LocalDatabase.forDatabase(db);

      const patientId = 'shared_patient';
      const originA = 'https://cloud-region-1.invalid';
      const originB = 'https://cloud-region-2.invalid';

      // Insert data for Server A
      await store.upsertEmergencyContact(
        const EmergencyContact(
          id: 'contact_a',
          patientId: patientId,
          serverOrigin: originA,
          name: 'Contact Region 1',
          phone: '111',
        ),
      );
      await store.insertTrigger(
        TriggerEntry(
          id: 'trig_a',
          patientId: patientId,
          serverOrigin: originA,
          occurredAt: DateTime.utc(2026, 3, 1),
          kind: TriggerKind.sleep,
        ),
      );
      await store.insertMessage(
        ChatMessage(
          id: 'msg_a',
          patientId: patientId,
          serverOrigin: originA,
          senderId: 'user_a',
          senderName: 'Alice',
          senderRole: UserRole.patient,
          channelType: 'family_patient',
          content: 'Hello Server A',
          createdAt: DateTime.utc(2026, 3, 1),
        ),
      );

      // Insert data for Server B
      await store.upsertEmergencyContact(
        const EmergencyContact(
          id: 'contact_b',
          patientId: patientId,
          serverOrigin: originB,
          name: 'Contact Region 2',
          phone: '222',
        ),
      );
      await store.insertTrigger(
        TriggerEntry(
          id: 'trig_b',
          patientId: patientId,
          serverOrigin: originB,
          occurredAt: DateTime.utc(2026, 3, 2),
          kind: TriggerKind.fatigue,
        ),
      );
      await store.insertMessage(
        ChatMessage(
          id: 'msg_b',
          patientId: patientId,
          serverOrigin: originB,
          senderId: 'user_b',
          senderName: 'Bob',
          senderRole: UserRole.patient,
          channelType: 'family_patient',
          content: 'Hello Server B',
          createdAt: DateTime.utc(2026, 3, 2),
        ),
      );

      // Query Server A
      final contactsA = await store.emergencyContactsFor(patientId, serverOrigin: originA);
      expect(contactsA.map((c) => c.name), contains('Contact Region 1'));
      expect(contactsA.map((c) => c.name), isNot(contains('Contact Region 2')));

      final triggersA = await store.triggersFor(patientId, serverOrigin: originA);
      expect(triggersA.map((t) => t.id), ['trig_a']);

      final messagesA = await store.messagesForChannel(patientId, 'family_patient', serverOrigin: originA);
      expect(messagesA.map((m) => m.content), ['Hello Server A']);

      // Query Server B
      final contactsB = await store.emergencyContactsFor(patientId, serverOrigin: originB);
      expect(contactsB.map((c) => c.name), contains('Contact Region 2'));
      expect(contactsB.map((c) => c.name), isNot(contains('Contact Region 1')));

      final triggersB = await store.triggersFor(patientId, serverOrigin: originB);
      expect(triggersB.map((t) => t.id), ['trig_b']);

      final messagesB = await store.messagesForChannel(patientId, 'family_patient', serverOrigin: originB);
      expect(messagesB.map((m) => m.content), ['Hello Server B']);

      await db.close();
    });

    test('Multi-device conflict detection triggers banner and allows user resolution', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalDatabase.createTestSchema(db);
      final store = LocalDatabase.forDatabase(db);

      const pid = 'patient_conflict_test';
      const origin = 'https://epilepsy.example.com';

      final api = _FakeApi(origin: origin, subject: 'user_1')..online = false;
      final care = CareService(api: api, db: store);
      await care.loadFor(pid);

      // 1. Patient makes local edits offline
      await care.saveMedicalCard(
        MedicalCard(
          patientId: pid,
          serverOrigin: origin,
          diagnosis: 'Local Unsaved Diagnosis',
          allergies: 'Aspirin',
          synced: false,
        ),
      );

      expect(care.medicalCard?.diagnosis, 'Local Unsaved Diagnosis');
      expect(care.medicalCard?.synced, isFalse);
      expect(care.hasCardConflict, isFalse);

      // 2. Server returns a different remote update made on another device
      api.remoteCard = {
        'patient_id': pid,
        'diagnosis': 'Remote Hospital Diagnosis',
        'allergies': 'Penicillin, Aspirin',
        'updated_at': DateTime.utc(2026, 4, 1).toIso8601String(),
      };

      await care.refresh();

      // Conflict must be detected!
      expect(care.hasCardConflict, isTrue);
      expect(care.cardConflict?.diagnosis, 'Remote Hospital Diagnosis');
      // Local version is kept until user resolves
      expect(care.medicalCard?.diagnosis, 'Local Unsaved Diagnosis');

      // 3. User chooses to keep local version
      await care.resolveCardConflict(keepLocal: true);
      expect(care.hasCardConflict, isFalse);
      expect(care.cardConflict, isNull);
      expect(care.medicalCard?.diagnosis, 'Local Unsaved Diagnosis');

      // 4. Simulate conflict again with another local edit and choose to accept server version
      await care.saveMedicalCard(
        MedicalCard(
          patientId: pid,
          serverOrigin: origin,
          diagnosis: 'Another Unsaved Edit',
          synced: false,
        ),
      );
      api.remoteCard = {
        'patient_id': pid,
        'diagnosis': 'Remote Hospital Diagnosis v2',
        'allergies': 'Penicillin, Aspirin',
        'updated_at': DateTime.utc(2026, 4, 2).toIso8601String(),
      };
      await care.refresh();
      expect(care.hasCardConflict, isTrue);

      await care.resolveCardConflict(keepLocal: false);
      expect(care.hasCardConflict, isFalse);
      expect(care.medicalCard?.diagnosis, 'Remote Hospital Diagnosis v2');
      expect(care.medicalCard?.synced, isTrue);

      care.dispose();
      await db.close();
    });
  });
}
