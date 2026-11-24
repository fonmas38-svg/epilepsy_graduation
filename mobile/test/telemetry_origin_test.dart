import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/services/local_database.dart';

void main() {
  late Database sql;
  late LocalDatabase db;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalDatabase.createTestSchema(sql);
    db = LocalDatabase.forDatabase(sql);
  });
  tearDown(() async => sql.close());

  test(
    'acknowledgement and delivery commit together and roll back on queue failure',
    () async {
      for (final origin in ['a', 'b']) {
        await db.insertAlert(
          AlertItem(
            id: 'ack',
            patientId: 'p',
            serverOrigin: origin,
            timestamp: DateTime.now(),
            severity: 'critical',
            message: 'Review',
            recipients: [],
          ),
        );
      }
      final delivery = OutboxItem(
        id: 'delivery',
        method: 'POST',
        path: '/alerts/ack',
        body: {'alertId': 'ack', '_ownerOrigin': 'a'},
        createdAt: DateTime.now(),
      );
      await sql.insert('outbox', delivery.toMap());
      await expectLater(
        db.acknowledgeAndQueueAlert(
          id: 'ack',
          patientId: 'p',
          by: 'owner',
          serverOrigin: 'a',
          delivery: delivery,
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await db.alertsFor('p', serverOrigin: 'a')).single.acknowledged,
        isFalse,
      );
      await sql.delete('outbox');
      await db.acknowledgeAndQueueAlert(
        id: 'ack',
        patientId: 'p',
        by: 'owner',
        serverOrigin: 'a',
        delivery: delivery,
      );
      expect(
        (await db.alertsFor('p', serverOrigin: 'a')).single.acknowledged,
        isTrue,
      );
      expect(
        (await db.alertsFor('p', serverOrigin: 'b')).single.acknowledged,
        isFalse,
      );
      expect(await sql.query('outbox'), hasLength(1));
    },
  );

  test(
    'identical telemetry IDs on two servers survive independently; legacy rows are quarantined',
    () async {
      for (final origin in ['', 'https://a.invalid', 'https://b.invalid']) {
        await db.insertReading(
          VitalReading(
            id: 'same',
            patientId: 'p',
            serverOrigin: origin,
            timestamp: DateTime.now(),
            eeg: [1],
            ecg: [2],
            motion: [3],
            hr: 70,
          ),
        );
        await db.insertAssessment(
          RiskAssessment(
            id: 'same',
            patientId: 'p',
            serverOrigin: origin,
            timestamp: DateTime.now(),
            label: RiskLabel.watch,
            confidence: .8,
            features: {},
            processingMs: 1,
          ),
        );
        await db.insertAlert(
          AlertItem(
            id: 'same',
            patientId: 'p',
            serverOrigin: origin,
            timestamp: DateTime.now(),
            severity: 'critical',
            message: origin,
            recipients: [],
          ),
        );
        await db.insertPredictionEvent(
          PredictionEvent(
            id: 'same',
            patientId: 'p',
            serverOrigin: origin,
            firedAt: DateTime.now(),
            preictalProb: .2,
            outcome: 'escalated',
          ),
        );
      }
      for (final origin in ['https://a.invalid', 'https://b.invalid']) {
        expect(
          (await db.recentReadings(
            'p',
            serverOrigin: origin,
          )).single.serverOrigin,
          origin,
        );
        expect(
          (await db.assessmentsFor(
            'p',
            serverOrigin: origin,
          )).single.serverOrigin,
          origin,
        );
        expect(
          (await db.alertsFor('p', serverOrigin: origin)).single.message,
          origin,
        );
        expect(
          (await db.predictionEventsFor(
            'p',
            serverOrigin: origin,
          )).single.serverOrigin,
          origin,
        );
      }
      await db.markSynced(['same'], serverOrigin: 'https://a.invalid');
      expect(
        await db.unsyncedReadings('p', serverOrigin: 'https://a.invalid'),
        isEmpty,
      );
      expect(
        await db.unsyncedReadings('p', serverOrigin: 'https://b.invalid'),
        hasLength(1),
      );
      expect(await db.unsyncedReadings('p'), hasLength(1));
      await db.acknowledgeAlert(
        'same',
        'owner',
        serverOrigin: 'https://a.invalid',
      );
      expect(
        (await db.alertsFor(
          'p',
          serverOrigin: 'https://b.invalid',
        )).single.acknowledged,
        isFalse,
      );
    },
  );

  test(
    'v8 composite-key migration preserves legacy payloads and indexes and can repeat',
    () async {
      final legacy = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        for (final table in [
          'readings',
          'assessments',
          'alerts',
          'prediction_events',
        ]) {
          await legacy.execute(
            "CREATE TABLE $table (id TEXT PRIMARY KEY, patientId TEXT, timestamp TEXT, payload TEXT, serverOrigin TEXT NOT NULL DEFAULT '')",
          );
          await legacy.execute(
            'CREATE INDEX idx_${table}_test ON $table (patientId)',
          );
          await legacy.insert(table, {
            'id': 'old',
            'patientId': 'p',
            'payload': 'preserve',
          });
        }
        await legacy.transaction((txn) async {
          await migrateTelemetryOrigins(txn);
        });
        await migrateTelemetryOrigins(legacy);
        for (final table in [
          'readings',
          'assessments',
          'alerts',
          'prediction_events',
        ]) {
          await legacy.insert(table, {
            'id': 'old',
            'patientId': 'p',
            'serverOrigin': 'https://a.invalid',
          });
          expect(await legacy.query(table), hasLength(2));
          expect(
            (await legacy.query(
              table,
              where: "serverOrigin = ''",
            )).single['payload'],
            'preserve',
          );
          expect(
            await legacy.rawQuery(
              "SELECT name FROM sqlite_master WHERE name = 'idx_${table}_test'",
            ),
            hasLength(1),
          );
        }
      } finally {
        await legacy.close();
      }
    },
  );

  test(
    'dashboard and offline review cover more than 100 alerts and respect origin and patient scope',
    () async {
      final batch = sql.batch();
      for (var i = 0; i < 360; i++) {
        batch.insert('assessments', {
          'id': 'a-$i',
          'patientId': 'p-$i',
          'serverOrigin': 'a',
          'timestamp': '2026-11-24T12:00:00Z',
          'label': 'watch',
          'confidence': .7,
          'features': jsonEncode({}),
          'processingMs': 1,
        });
      }
      for (var i = 0; i < 125; i++) {
        batch.insert('alerts', {
          'id': 'q-$i',
          'patientId': 'p-0',
          'serverOrigin': 'a',
          'timestamp': DateTime.utc(2026, 11, 24, 12, i).toIso8601String(),
          'severity': 'critical',
          'message': 'Review',
          'recipients': '[]',
        });
      }
      batch.insert('alerts', {
        'id': 'foreign',
        'patientId': 'p-0',
        'serverOrigin': 'b',
        'timestamp': '2026-11-24T13:00:00Z',
        'severity': 'critical',
        'message': 'Private',
        'recipients': '[]',
      });
      await batch.commit(noResult: true);
      final snapshot = await db.dashboardSnapshot(
        List.generate(360, (i) => 'p-$i'),
        serverOrigin: 'a',
        includeCare: false,
      );
      expect(snapshot.latest, hasLength(360));
      expect(snapshot.alerts['p-0'], hasLength(100));
      final first = await db.pendingReviewAlerts(
        ['p-0'],
        serverOrigin: 'a',
        limit: 50,
      );
      final second = await db.pendingReviewAlerts(
        ['p-0'],
        serverOrigin: 'a',
        offset: 50,
        limit: 100,
      );
      expect(first.length + second.length, 125);
      expect({
        ...first.map((a) => a.id),
        ...second.map((a) => a.id),
      }, hasLength(125));
      expect(
        await db.pendingReviewAlerts(['other'], serverOrigin: 'a'),
        isEmpty,
      );
    },
  );
}
