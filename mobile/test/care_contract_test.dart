import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/care_service.dart';
import 'care_outbox_test.dart' show QueueApi, QueueDb;
import 'api_session_boundary_test.dart' show SwitchingTokens;
import 'manual_entry_test.dart' show CareDb;

class ContactApi extends QueueApi {
  List<String> deletedTriggerIds = [];
  List<Map<String, dynamic>> remoteTriggers = [];
  @override
  Future<List<Map<String, dynamic>>> getList(String path) async =>
      path.endsWith('emergency-contacts')
      ? [
          {'id': 'contact', 'name': 'Old remote name', 'phone': '123'},
        ]
      : [];
  @override
  Future<Map<String, dynamic>> getObject(String path) async =>
      path.endsWith('triggers')
      ? {'triggers': remoteTriggers, 'deleted_ids': deletedTriggerIds}
      : {};
}

class ContactDb extends CareDb {
  final deletedPaths = <String>{};
  final triggers = <TriggerEntry>[];
  final contacts = <EmergencyContact>[
    const EmergencyContact(
      id: 'contact',
      patientId: 'p',
      name: 'New local name',
      phone: '456',
    ),
  ];
  @override
  Future<List<EmergencyContact>> emergencyContactsFor(
    String patientId, {
    String? serverOrigin,
  }) async =>
      List.of(
        contacts.where(
          (c) =>
              serverOrigin == null ||
              serverOrigin.isEmpty ||
              c.serverOrigin == serverOrigin ||
              c.serverOrigin.isEmpty,
        ),
      );
  @override
  Future<void> upsertEmergencyContact(EmergencyContact contact) async {
    if (delayedSave != null) await delayedSave!.future;
    contacts.removeWhere((row) => row.id == contact.id);
    contacts.add(contact);
  }

  @override
  Future<List<OutboxItem>> pendingOutbox({
    int limit = 100,
    String? onlyPath,
    String? excludePath,
    String? ownerId,
  }) async => [];

  @override
  Future<Set<String>> queuedCareDeletes({
    required String patientId,
    required String ownerId,
    required String origin,
  }) async => deletedPaths;
  @override
  Future<List<TriggerEntry>> triggersFor(
    String patientId, {
    DateTime? since,
    int limit = 200,
    String? serverOrigin,
  }) async =>
      List.of(
        triggers.where(
          (t) =>
              serverOrigin == null ||
              serverOrigin.isEmpty ||
              t.serverOrigin == serverOrigin ||
              t.serverOrigin.isEmpty,
        ),
      );
  @override
  Future<void> insertTrigger(TriggerEntry entry) async {
    triggers.removeWhere((row) => row.id == entry.id);
    triggers.add(entry);
  }

  @override
  Future<void> removeSyncedCareRows({
    required String table,
    required String patientId,
    required List<String> ids,
    String? serverOrigin,
  }) async {
    triggers.removeWhere(
      (row) =>
          row.patientId == patientId &&
          row.synced &&
          ids.contains(row.id) &&
          (serverOrigin == null ||
              serverOrigin.isEmpty ||
              row.serverOrigin == serverOrigin ||
              row.serverOrigin.isEmpty),
    );
  }
}

class NotesApi extends QueueApi {
  final response = Completer<List<Map<String, dynamic>>>();
  @override
  Future<List<Map<String, dynamic>>> getList(String path) => response.future;
}

class NotesDb extends QueueDb {
  final notes = <ClinicalNote>[];
  @override
  Future<void> upsertClinicalNote(ClinicalNote note) async => notes.add(note);
  @override
  Future<List<ClinicalNote>> clinicalNotesFor(
    String patientId, {
    int limit = 100,
    String? serverOrigin,
  }) async =>
      notes
          .where(
            (note) =>
                note.patientId == patientId &&
                (serverOrigin == null ||
                    serverOrigin.isEmpty ||
                    note.serverOrigin == serverOrigin),
          )
          .toList();
}

void main() {
  test('pending contact deletion is not resurrected by refresh', () async {
    final db = ContactDb()..contacts.clear();
    db.deletedPaths.add('/patients/p/emergency-contacts/contact');
    final care = CareService(api: ContactApi(), db: db);
    await care.loadFor('p');
    expect(care.contacts, isEmpty);
    expect(care.failure, isNull);
    care.dispose();
  });

  test(
    'remote trigger tombstone removes a synced record on another device',
    () async {
      final db = ContactDb();
      db.triggers.add(
        TriggerEntry(
          id: 'gone',
          patientId: 'p',
          occurredAt: DateTime.utc(2026),
          kind: TriggerKind.stress,
          synced: true,
        ),
      );
      final api = ContactApi()..deletedTriggerIds = ['gone'];
      final care = CareService(api: api, db: db);
      await care.loadFor('p');
      expect(care.triggers, isEmpty);
      expect(care.failure, isNull);
      care.dispose();
    },
  );
  test(
    'contact save retains original account and server across local delay',
    () async {
      final db = ContactDb()..delayedSave = Completer<void>();
      final api = ContactApi();
      final care = CareService(api: api, db: db);
      await care.loadFor('p', remote: false);
      final save = care.saveContact(name: 'Family', phone: '123');
      care.clearSession();
      api.tokens.subject = 'another';
      api.baseUrl = 'https://another.invalid';
      db.delayedSave!.complete();
      await save;
      expect(db.queue.single.body['_ownerId'], 'p');
      expect(db.queue.single.body['_ownerOrigin'], 'https://one.invalid');
      expect(care.contacts, isEmpty);
      care.dispose();
    },
  );
  test('remote refresh preserves an unsent local contact edit', () async {
    final db = ContactDb();
    final care = CareService(api: ContactApi(), db: db);
    await care.loadFor('p');
    expect(care.contacts.single.name, 'New local name');
    expect(care.contacts.single.synced, isFalse);
    care.dispose();
  });
  test(
    'late clinical notes cannot enter storage after account switch',
    () async {
      final api = NotesApi();
      final db = NotesDb();
      final care = CareService(api: api, db: db);
      final pending = care.clinicalNotesFor('p', refreshRemote: true);
      api.tokens.subject = 'another-account';
      api.tokens.revision++;
      api.response.complete([
        {
          'id': 'old-note',
          'text': 'Private',
          'written_at': '2026-11-13T10:00:00Z',
        },
      ]);
      expect(await pending, isEmpty);
      expect(db.notes, isEmpty);
      care.dispose();
    },
  );
  test('trigger envelope is accepted by generic care reader', () async {
    final api = ApiClient(
      tokens: SwitchingTokens(),
      baseUrl: 'https://one.invalid',
      client: MockClient(
        (_) async =>
            http.Response('{"triggers":[{"id":"entry","kind":"stress"}]}', 200),
      ),
    );
    expect((await api.getList('/patients/p/triggers')).single['id'], 'entry');
  });

  test(
    'malformed lists cannot be interpreted as an empty remote snapshot',
    () async {
      for (final body in ['{}', '{"items":null}', '[{"id":"valid"},null]']) {
        final api = ApiClient(
          tokens: SwitchingTokens(),
          baseUrl: 'https://one.invalid',
          client: MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(
          api.getList('/patients/p/emergency-contacts'),
          throwsFormatException,
        );
      }
    },
  );

  test('care timestamps preserve instants and server note authors', () {
    final at = DateTime.parse('2026-11-13T12:00:00+03:00');
    final note = ClinicalNote.fromMap({
      'id': 'note',
      'patientId': 'p',
      'text': 'Observation',
      'written_at': at.toUtc().toIso8601String(),
      'doctor_id': 'doctor',
    });
    expect(note.writtenAt, at);
    expect(note.doctorId, 'doctor');
    expect(note.toApiJson()['written_at'], '2026-11-13T09:00:00.000Z');
  });
}
