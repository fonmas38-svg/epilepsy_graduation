import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/features/patient/patient_entry_screen.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/care_service.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'message_session_test.dart' show MessageApi;
import 'redesign_navigation_test.dart' show harness;

class CareDb implements LocalDatabase {
  final logs = <SeizureLog>[];
  final queue = <OutboxItem>[];
  @override
  Future<List<OutboxItem>> careOutboxForOwner(
    String ownerId, {
    String? origin,
  }) async =>
      queue
          .where(
            (item) =>
                item.body['_ownerId'] == ownerId &&
                (origin == null ||
                    origin.isEmpty ||
                    item.body['_ownerOrigin'] == origin),
          )
          .toList();
  Completer<List<EmergencyContact>>? delayedContacts;
  Completer<void>? delayedSave;
  @override
  Future<List<EmergencyContact>> emergencyContactsFor(
    String patientId, {
    String? serverOrigin,
  }) async =>
      delayedContacts == null ? [] : delayedContacts!.future;
  @override
  Future<MedicalCard?> medicalCardFor(
    String patientId, {
    String? serverOrigin,
  }) async => null;
  @override
  Future<List<TriggerEntry>> triggersFor(
    String patientId, {
    DateTime? since,
    int limit = 200,
    String? serverOrigin,
  }) async => [];
  @override
  Future<List<CaregiverConsent>> consentsFor(
    String patientId, {
    bool activeOnly = false,
    String? serverOrigin,
  }) async => [];
  @override
  Future<List<AccessLogEntry>> accessLogFor(
    String patientId, {
    int limit = 100,
    String? serverOrigin,
  }) async => [];
  @override
  Future<List<SeizureLog>> seizureLogsFor(
    String patientId, {
    DateTime? since,
    int limit = 200,
    String? serverOrigin,
  }) async => logs.where((row) => row.patientId == patientId).toList();
  @override
  Future<List<Adjudication>> adjudicationsFor(
    String patientId, {
    int limit = 200,
    String? serverOrigin,
  }) async => [];
  @override
  Future<int> pendingOutboxCount() async => queue.length;
  @override
  Future<void> upsertSeizureLog(SeizureLog row) async {
    if (delayedSave != null) await delayedSave!.future;
    logs.removeWhere((previous) => previous.id == row.id);
    logs.add(row);
  }

  @override
  Future<void> enqueueOutbox(OutboxItem row) async {
    queue.add(row);
  }

  @override
  Future<void> persistCareWrite({
    required OutboxItem item,
    String? table,
    Map<String, Object?>? row,
    String? deleteId,
    String? patientId,
  }) async {
    if (row != null) {
      if (table == 'seizure_logs') {
        await upsertSeizureLog(
          SeizureLog.fromMap(Map<String, dynamic>.from(row)),
        );
      }
      if (table == 'emergency_contacts') {
        await upsertEmergencyContact(
          EmergencyContact.fromMap(Map<String, dynamic>.from(row)),
        );
      }
    }
    await enqueueOutbox(item);
  }

  @override
  Future<Set<String>> queuedCareDeletes({
    required String patientId,
    required String ownerId,
    required String origin,
  }) async => {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'a report retains its original owner when the account changes during local save',
    () async {
      final db = CareDb()..delayedSave = Completer<void>();
      final api = MessageApi();
      final care = CareService(api: api, db: db);
      await care.loadFor('p1', remote: false);
      final pending = care.logSeizure(
        occurredAt: DateTime.now().toUtc(),
        reportedBy: 'p1',
      );
      care.clearSession();
      api.tokens.subject = 'p2';
      db.delayedSave!.complete();
      await pending;
      expect(db.queue.single.body['_ownerId'], 'p1');
      expect(db.queue.single.path, '/patients/p1/seizure-logs');
      expect(care.patientId, isNull);
      expect(care.seizureLogs, isEmpty);
    },
  );
  test(
    'care cache cannot reappear when an old local read completes after logout',
    () async {
      final db = CareDb()
        ..delayedContacts = Completer<List<EmergencyContact>>();
      final care = CareService(api: MessageApi(), db: db);
      final pending = care.loadFor('p1', remote: false);
      care.clearSession();
      db.delayedContacts!.complete([]);
      await pending;
      expect(care.patientId, isNull);
      expect(care.hasLocalData, isFalse);
      expect(care.contacts, isEmpty);
      expect(care.loading, isFalse);
    },
  );
  testWidgets(
    'manual report validates duration then saves a UTC event and a durable sync intent',
    (tester) async {
      final db = CareDb();
      final state = AppState(database: db, apiClient: MessageApi());
      await state.auth.applyBackendSession({
        'user': {
          'id': 'p1',
          'role': 'patient',
          'name': 'Patient',
          'username': 'patient',
        },
        'patients': [
          {'id': 'p1', 'name': 'Patient'},
        ],
      });
      await tester.pumpWidget(
        harness(
          state,
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const SeizureEntryScreen(),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final duration = find.byType(TextFormField).first;
      await tester.enterText(duration, '-2');
      await tester.ensureVisible(find.text('حفظ البلاغ'));
      await tester.tap(find.text('حفظ البلاغ'));
      await tester.pumpAndSettle();
      expect(db.logs, isEmpty);
      await tester.ensureVisible(duration);
      await tester.enterText(duration, '45');
      await tester.enterText(find.byType(TextFormField).last, 'Observed event');
      await tester.ensureVisible(find.text('حفظ البلاغ'));
      await tester.tap(find.text('حفظ البلاغ'));
      await tester.pumpAndSettle();
      expect(db.logs.single.patientId, 'p1');
      expect(db.logs.single.durationSeconds, 45);
      expect(db.logs.single.type, SeizureType.other);
      expect(db.logs.single.occurredAt.isUtc, isTrue);
      expect(db.queue.single.path, '/patients/p1/seizure-logs');
      expect(db.queue.single.body['id'], db.logs.single.id);
      expect(
        (db.queue.single.body['occurred_at'] as String).endsWith('Z'),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
