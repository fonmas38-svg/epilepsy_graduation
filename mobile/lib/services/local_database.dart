import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../core/config.dart';
import '../core/enums.dart';
import '../models/care_models.dart';
import '../models/message_model.dart';
import '../models/models.dart';
import 'secure_store.dart';
import 'signal_simulator.dart';

/// Additive and idempotent: preserve every existing alert and acknowledgment.
Future<void> migrateAlertDetails(DatabaseExecutor db) async {
  final columns = await db.rawQuery('PRAGMA table_info(alerts)');
  if (columns.any((column) => column['name'] == 'details')) return;
  await db.execute(
    "ALTER TABLE alerts ADD COLUMN details TEXT NOT NULL DEFAULT '{}'",
  );
}

/// Additive and idempotent: isolates stored data by server origin and account,
/// preventing cross-server/cross-account bleed or collisions. Preserves all legacy
/// data as serverOrigin = '' without data loss.
Future<void> migrateOriginIsolation(DatabaseExecutor db) async {
  final tables = const [
    'readings',
    'assessments',
    'alerts',
    'medications',
    'medication_logs',
    'prediction_events',
    'emergency_contacts',
    'trigger_entries',
    'consents',
    'access_log',
    'seizure_logs',
    'adjudications',
    'alert_responses',
    'clinical_notes',
    'messages',
  ];

  for (final table in tables) {
    final tableExists = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='$table'",
    )).isNotEmpty;
    if (!tableExists) continue;

    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (!columns.any((column) => column['name'] == 'serverOrigin')) {
      await db.execute(
        "ALTER TABLE $table ADD COLUMN serverOrigin TEXT NOT NULL DEFAULT ''",
      );
    }
  }

  // Handle medical_card composite primary key (patientId, serverOrigin)
  final cardExists = (await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='medical_card'",
  )).isNotEmpty;
  if (cardExists) {
    final cardCols = await db.rawQuery('PRAGMA table_info(medical_card)');
    if (!cardCols.any((column) => column['name'] == 'serverOrigin')) {
      await db.execute('ALTER TABLE medical_card RENAME TO _legacy_medical_card');
      await db.execute('''
        CREATE TABLE medical_card (
          patientId TEXT NOT NULL,
          serverOrigin TEXT NOT NULL DEFAULT '',
          diagnosis TEXT NOT NULL DEFAULT '',
          allergies TEXT NOT NULL DEFAULT '',
          bloodType TEXT NOT NULL DEFAULT '',
          doctorName TEXT NOT NULL DEFAULT '',
          doctorPhone TEXT NOT NULL DEFAULT '',
          notes TEXT NOT NULL DEFAULT '',
          updatedAt TEXT NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (patientId, serverOrigin)
        )
      ''');
      await db.execute('''
        INSERT INTO medical_card (
          patientId, serverOrigin, diagnosis, allergies, bloodType,
          doctorName, doctorPhone, notes, updatedAt, synced
        )
        SELECT patientId, '', diagnosis, allergies, bloodType,
               doctorName, doctorPhone, notes, updatedAt, synced
        FROM _legacy_medical_card
      ''');
      await db.execute('DROP TABLE _legacy_medical_card');
    }
  }

  for (final table in const [
    'emergency_contacts',
    'trigger_entries',
    'consents',
    'access_log',
    'seizure_logs',
    'adjudications',
    'alert_responses',
    'clinical_notes',
    'messages',
  ]) {
    final exists = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='$table'",
    )).isNotEmpty;
    if (exists) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_${table}_patient_origin ON $table (patientId, serverOrigin)',
      );
    }
  }
}

/// Platform-adaptive local database.
///
/// * Android / iOS  — full SQLCipher encryption (256-bit AES). The key is
///   generated once per install and kept in the platform keychain
///   (Keystore / Keychain), never in plaintext prefs. Dumping the DB file off
///   the device is useless without that key.
/// * Windows / desktop — SQLCipher's native library is not available, so we fall
///   back to plain SQLite via `sqflite_common_ffi`. Data at rest is not
///   encrypted there; desktop is a development/clinician workstation target and
///   the sensitive path (the patient's phone) stays encrypted.
///
/// The rest of the class (queries, schema) is identical on both — only the
/// `openDatabase` call differs.
class LocalDatabase {
  LocalDatabase._();
  @visibleForTesting
  LocalDatabase.forDatabase(Database db) : _db = db;

  /// Initializes an isolated test database using the production schema only.
  /// Never opens the patient's database or reads its encryption key.
  @visibleForTesting
  static Future<void> createTestSchema(Database db) =>
      LocalDatabase.forDatabase(db)._createSchema(db, _dbVersion);

  static final LocalDatabase instance = LocalDatabase._();

  Database? _db;
  static const _kDbKey = 'local_db_encryption_key';

  /// Schema version. v1 = readings/assessments/alerts. v2 = + medication
  /// adherence (medications, medication_logs) and prediction_events. v3 = + the
  /// care tables the offline requirement in `docs/frontend-plan-ar.md` §2.5 asks
  /// for (emergency contacts, medical card, trigger diary, consents, access log,
  /// seizure logs, adjudications, alert responses, clinical notes) plus the
  /// outgoing `outbox` queue. v4 = + messages table for doctor and family channels.
  /// v5 adds alert details through an additive migration, preserving existing rows.
  /// v6 adds origin and account isolation to eliminate cross-server collisions.
  /// v7 adds encrypted user_credentials table for offline authentication.
  static const _dbVersion = 7;

  /// True on desktop platforms where SQLCipher is unavailable.
  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    if (_isDesktop) return _openDesktop();
    return _openEncrypted();
  }

  /// Android / iOS: encrypted SQLCipher database.
  Future<Database> _openEncrypted() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'epilepsy_monitor.db');
    // 256-bit key from secure storage (iOS Keychain / Android Keystore).
    final key = await SecureStore.instance.readOrCreateSecret(
      _kDbKey,
      byteLength: 32,
      allowCreate: !await File(path).exists(),
    );
    return openDatabase(
      path,
      version: _dbVersion,
      password: key,
      onCreate: _createSchema,
      onUpgrade: _onUpgrade,
    );
  }

  /// Windows / desktop: plain SQLite through the FFI factory.
  Future<Database> _openDesktop() async {
    ffi.sqfliteFfiInit();
    final factory = ffi.databaseFactoryFfi;
    final dbPath = await factory.getDatabasesPath();
    final path = p.join(dbPath, 'epilepsy_monitor.db');
    return factory.openDatabase(
      path,
      options: ffi.OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: _createSchema,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
          CREATE TABLE readings (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            eeg TEXT NOT NULL,
            ecg TEXT NOT NULL,
            motion TEXT NOT NULL,
            hr REAL NOT NULL,
            synced INTEGER NOT NULL DEFAULT 0,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE assessments (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            label TEXT NOT NULL,
            confidence REAL NOT NULL,
            features TEXT NOT NULL,
            processingMs REAL NOT NULL,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE alerts (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            severity TEXT NOT NULL,
            message TEXT NOT NULL,
            recipients TEXT NOT NULL,
            acknowledged INTEGER NOT NULL DEFAULT 0,
            acknowledgedBy TEXT,
            details TEXT NOT NULL DEFAULT '{}',
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    // v2/v3/v4/v7 tables are created here for fresh installs and in _onUpgrade for
    // existing ones. Same idempotent DDL is used in both paths.
    await _createV2Tables(db);
    await _createV3Tables(db);
    await _createV4Tables(db);
    await _createV7Tables(db);
  }

  /// Additive migrations preserve existing rows; v5 adds alert context.
  /// v6 adds origin isolation for care, telemetry, and messages.
  /// v7 adds encrypted user_credentials for offline credential validation.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createV2Tables(db);
    }
    if (oldVersion < 3) {
      await _createV3Tables(db);
    }
    if (oldVersion < 4) {
      await _createV4Tables(db);
    }
    if (oldVersion < 5) {
      await migrateAlertDetails(db);
    }
    if (oldVersion < 6) {
      await migrateOriginIsolation(db);
    }
    if (oldVersion < 7) {
      await _createV7Tables(db);
    }
  }

  /// Medication-adherence + prediction-event tables (schema v2). Uses
  /// `IF NOT EXISTS` so it is safe to run on both fresh installs and upgrades.
  Future<void> _createV2Tables(Database db) async {
    await db.execute('''
          CREATE TABLE IF NOT EXISTS medications (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            name TEXT NOT NULL,
            dosage TEXT NOT NULL DEFAULT '',
            schedule TEXT NOT NULL DEFAULT '',
            times TEXT NOT NULL DEFAULT '[]',
            active INTEGER NOT NULL DEFAULT 1,
            createdAt TEXT NOT NULL,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS medication_logs (
            id TEXT PRIMARY KEY,
            medicationId TEXT NOT NULL,
            patientId TEXT NOT NULL,
            scheduledFor TEXT NOT NULL,
            takenAt TEXT,
            status TEXT NOT NULL DEFAULT 'taken',
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS prediction_events (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            firedAt TEXT NOT NULL,
            preictalProb REAL NOT NULL,
            leadTimeMin REAL,
            horizonMin REAL,
            source TEXT,
            outcome TEXT NOT NULL,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
  }

  /// Care tables (schema v3) — the offline surface required by
  /// `docs/frontend-plan-ar.md` §2.5: «السجل الطبي، الأدوية، جهات الاتصال، آخر
  /// حالة معروفة، خطة الطوارئ» must all be readable with zero network, and every
  /// write made while offline must survive in a queue.
  ///
  /// Deliberately **not** here: raw signal. §2.5 forbids caching it, and the
  /// existing `readings` table is a short-lived sync buffer pruned to
  /// [AppConfig.localRetention], not a record.
  ///
  /// Every statement uses `IF NOT EXISTS` so it is safe on fresh installs and on
  /// upgrades, and safe to re-run if an upgrade is interrupted midway.
  Future<void> _createV3Tables(Database db) async {
    await db.execute('''
          CREATE TABLE IF NOT EXISTS emergency_contacts (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            name TEXT NOT NULL,
            phone TEXT NOT NULL,
            relation TEXT NOT NULL DEFAULT '',
            priority INTEGER NOT NULL DEFAULT 0,
            synced INTEGER NOT NULL DEFAULT 0,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS medical_card (
            patientId TEXT NOT NULL,
            serverOrigin TEXT NOT NULL DEFAULT '',
            diagnosis TEXT NOT NULL DEFAULT '',
            allergies TEXT NOT NULL DEFAULT '',
            bloodType TEXT NOT NULL DEFAULT '',
            doctorName TEXT NOT NULL DEFAULT '',
            doctorPhone TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            updatedAt TEXT NOT NULL,
            synced INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (patientId, serverOrigin)
          )
        ''');
    // `trigger_entries`, not `triggers`: TRIGGER is a SQL keyword and the plural
    // is close enough that some parsers stumble on it.
    await db.execute('''
          CREATE TABLE IF NOT EXISTS trigger_entries (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            occurredAt TEXT NOT NULL,
            kind TEXT NOT NULL,
            intensity INTEGER NOT NULL DEFAULT 3,
            note TEXT NOT NULL DEFAULT '',
            synced INTEGER NOT NULL DEFAULT 0,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS consents (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            caregiverId TEXT NOT NULL,
            caregiverName TEXT NOT NULL DEFAULT '',
            level TEXT NOT NULL DEFAULT 'alerts_only',
            shareLocation INTEGER NOT NULL DEFAULT 0,
            grantedAt TEXT NOT NULL,
            revokedAt TEXT,
            synced INTEGER NOT NULL DEFAULT 0,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS access_log (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            actorName TEXT NOT NULL DEFAULT '',
            action TEXT NOT NULL,
            at TEXT NOT NULL,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS seizure_logs (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            occurredAt TEXT NOT NULL,
            durationSeconds INTEGER,
            type TEXT NOT NULL DEFAULT 'other',
            notes TEXT NOT NULL DEFAULT '',
            reportedBy TEXT NOT NULL DEFAULT '',
            alertId TEXT,
            synced INTEGER NOT NULL DEFAULT 0,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS adjudications (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            alertId TEXT NOT NULL,
            verdict TEXT NOT NULL,
            decidedAt TEXT NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            doctorId TEXT NOT NULL DEFAULT '',
            synced INTEGER NOT NULL DEFAULT 0,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS alert_responses (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            alertId TEXT NOT NULL,
            responderId TEXT NOT NULL DEFAULT '',
            responderName TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'seen',
            at TEXT NOT NULL,
            synced INTEGER NOT NULL DEFAULT 0,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS clinical_notes (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            writtenAt TEXT NOT NULL,
            doctorId TEXT NOT NULL DEFAULT '',
            synced INTEGER NOT NULL DEFAULT 0,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS outbox (
            id TEXT PRIMARY KEY,
            method TEXT NOT NULL DEFAULT 'POST',
            path TEXT NOT NULL,
            body TEXT NOT NULL DEFAULT '{}',
            createdAt TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            lastError TEXT
          )
        ''');
    // Every care query filters by patient; these keep the emergency screen fast
    // even after months of diary entries.
    for (final table in const [
      'emergency_contacts',
      'trigger_entries',
      'consents',
      'access_log',
      'seizure_logs',
      'adjudications',
      'alert_responses',
      'clinical_notes',
    ]) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_${table}_patient ON $table (patientId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_${table}_patient_origin ON $table (patientId, serverOrigin)',
      );
    }
  }

  Future<void> insertReading(VitalReading reading) async {
    final db = await database;
    await db.insert('readings', {
      'id': reading.id,
      'patientId': reading.patientId,
      'timestamp': reading.timestamp.toIso8601String(),
      'eeg': encodeSignal(reading.eeg),
      'ecg': encodeSignal(reading.ecg),
      'motion': encodeSignal(reading.motion),
      'hr': reading.hr,
      'synced': reading.synced ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _pruneOld(db, reading.patientId);
  }

  Future<void> _pruneOld(Database db, String patientId) async {
    final cutoff = DateTime.now()
        .subtract(AppConfig.localRetention)
        .toIso8601String();
    await db.delete(
      'readings',
      where: 'patientId = ? AND timestamp < ?',
      whereArgs: [patientId, cutoff],
    );
  }

  Future<List<VitalReading>> recentReadings(
    String patientId, {
    int limit = 120,
  }) async {
    final db = await database;
    final rows = await db.query(
      'readings',
      where: 'patientId = ?',
      whereArgs: [patientId],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows
        .map(
          (r) => VitalReading(
            id: r['id'] as String,
            patientId: r['patientId'] as String,
            timestamp: DateTime.parse(r['timestamp'] as String),
            eeg: decodeSignal(r['eeg'] as String),
            ecg: decodeSignal(r['ecg'] as String),
            motion: decodeSignal(r['motion'] as String),
            hr: (r['hr'] as num).toDouble(),
            synced: (r['synced'] as int) == 1,
          ),
        )
        .toList();
  }

  Future<List<VitalReading>> unsyncedReadings(String patientId) async {
    final db = await database;
    final rows = await db.query(
      'readings',
      where: 'patientId = ? AND synced = 0',
      whereArgs: [patientId],
      orderBy: 'timestamp ASC',
    );
    return rows
        .map(
          (r) => VitalReading(
            id: r['id'] as String,
            patientId: r['patientId'] as String,
            timestamp: DateTime.parse(r['timestamp'] as String),
            eeg: decodeSignal(r['eeg'] as String),
            ecg: decodeSignal(r['ecg'] as String),
            motion: decodeSignal(r['motion'] as String),
            hr: (r['hr'] as num).toDouble(),
            synced: false,
          ),
        )
        .toList();
  }

  Future<void> markSynced(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final id in ids) {
      batch.update('readings', {'synced': 1}, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> insertAssessment(
    RiskAssessment a, {
    OutboxItem? delivery,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('assessments', {
        'id': a.id,
        'patientId': a.patientId,
        'timestamp': a.timestamp.toIso8601String(),
        'label': a.label.apiValue,
        'confidence': a.confidence,
        'features': jsonEncode(a.features),
        'processingMs': a.processingMs,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (delivery != null) {
        await txn.insert(
          'outbox',
          delivery.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  Future<RiskAssessment?> latestAssessment(String patientId) async {
    final db = await database;
    final rows = await db.query(
      'assessments',
      where: 'patientId = ?',
      whereArgs: [patientId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return RiskAssessment(
      id: r['id'] as String,
      patientId: r['patientId'] as String,
      timestamp: DateTime.parse(r['timestamp'] as String),
      label: RiskLabelX.fromApi(r['label'] as String),
      confidence: (r['confidence'] as num).toDouble(),
      features: Map<String, dynamic>.from(
        jsonDecode(r['features'] as String) as Map,
      ),
      processingMs: (r['processingMs'] as num).toDouble(),
    );
  }

  Future<List<RiskAssessment>> assessmentsFor(
    String patientId, {
    int limit = 100,
  }) async {
    final db = await database;
    final rows = await db.query(
      'assessments',
      where: 'patientId = ?',
      whereArgs: [patientId],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows
        .map(
          (r) => RiskAssessment(
            id: r['id'] as String,
            patientId: r['patientId'] as String,
            timestamp: DateTime.parse(r['timestamp'] as String),
            label: RiskLabelX.fromApi(r['label'] as String),
            confidence: (r['confidence'] as num).toDouble(),
            features: Map<String, dynamic>.from(
              jsonDecode(r['features'] as String) as Map,
            ),
            processingMs: (r['processingMs'] as num).toDouble(),
          ),
        )
        .toList();
  }

  Future<void> insertAlert(AlertItem alert, {OutboxItem? delivery}) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('alerts', {
        'id': alert.id,
        'patientId': alert.patientId,
        'timestamp': alert.timestamp.toIso8601String(),
        'severity': alert.severity,
        'message': alert.message,
        'recipients': jsonEncode(alert.recipients),
        'acknowledged': alert.acknowledged ? 1 : 0,
        'acknowledgedBy': alert.acknowledgedBy,
        'details': jsonEncode(alert.details),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (delivery != null) {
        await txn.insert(
          'outbox',
          delivery.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  Future<List<AlertItem>> alertsFor(String patientId, {int limit = 50}) async {
    final db = await database;
    final rows = await db.query(
      'alerts',
      where: 'patientId = ?',
      whereArgs: [patientId],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows
        .map(
          (r) => AlertItem(
            id: r['id'] as String,
            patientId: r['patientId'] as String,
            timestamp: DateTime.parse(r['timestamp'] as String),
            severity: r['severity'] as String,
            message: r['message'] as String,
            recipients: List<String>.from(
              jsonDecode(r['recipients'] as String) as List,
            ),
            acknowledged: (r['acknowledged'] as int) == 1,
            acknowledgedBy: r['acknowledgedBy'] as String?,
            details: Map<String, dynamic>.from(
              jsonDecode(r['details'] as String? ?? '{}') as Map,
            ),
          ),
        )
        .toList();
  }

  Future<void> acknowledgeAlert(String id, String by) async {
    final db = await database;
    await db.update(
      'alerts',
      {'acknowledged': 1, 'acknowledgedBy': by},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // -------------------------------------------------------------- medications
  Future<void> insertMedication(Medication m) async {
    final db = await database;
    await db.insert('medications', {
      'id': m.id,
      'patientId': m.patientId,
      'name': m.name,
      'dosage': m.dosage,
      'schedule': m.schedule,
      'times': jsonEncode(m.times),
      'active': m.active ? 1 : 0,
      'createdAt': m.createdAt.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Medication>> medicationsFor(
    String patientId, {
    bool activeOnly = false,
  }) async {
    final db = await database;
    final rows = await db.query(
      'medications',
      where: activeOnly ? 'patientId = ? AND active = 1' : 'patientId = ?',
      whereArgs: [patientId],
      orderBy: 'createdAt DESC',
    );
    return rows
        .map(
          (r) => Medication(
            id: r['id'] as String,
            patientId: r['patientId'] as String,
            name: r['name'] as String,
            dosage: r['dosage'] as String? ?? '',
            schedule: r['schedule'] as String? ?? '',
            times: List<String>.from(
              jsonDecode(r['times'] as String? ?? '[]') as List,
            ),
            active: (r['active'] as int? ?? 1) == 1,
            createdAt:
                DateTime.tryParse(r['createdAt'] as String? ?? '') ??
                DateTime.now(),
          ),
        )
        .toList();
  }

  Future<void> setMedicationActive(String id, bool active) async {
    final db = await database;
    await db.update(
      'medications',
      {'active': active ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteMedication(String id) async {
    final db = await database;
    await db.delete('medications', where: 'id = ?', whereArgs: [id]);
    await db.delete(
      'medication_logs',
      where: 'medicationId = ?',
      whereArgs: [id],
    );
  }

  Future<void> insertMedicationLog(MedicationLog log) async {
    final db = await database;
    await db.insert('medication_logs', {
      'id': log.id,
      'medicationId': log.medicationId,
      'patientId': log.patientId,
      'scheduledFor': log.scheduledFor.toUtc().toIso8601String(),
      'takenAt': log.takenAt?.toUtc().toIso8601String(),
      'status': log.status,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<MedicationLog>> medicationLogsFor(
    String patientId, {
    DateTime? since,
  }) async {
    final db = await database;
    final rows = await db.query(
      'medication_logs',
      where: since == null
          ? 'patientId = ?'
          : 'patientId = ? AND scheduledFor >= ?',
      whereArgs: since == null
          ? [patientId]
          : [patientId, since.toUtc().toIso8601String()],
      orderBy: 'scheduledFor DESC',
    );
    return rows
        .map((r) => MedicationLog.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  // --------------------------------------------------------- prediction events
  Future<void> insertPredictionEvent(PredictionEvent e) async {
    final db = await database;
    await db.insert(
      'prediction_events',
      e.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<PredictionEvent>> predictionEventsFor(
    String patientId, {
    int limit = 100,
  }) async {
    final db = await database;
    final rows = await db.query(
      'prediction_events',
      where: 'patientId = ?',
      whereArgs: [patientId],
      orderBy: 'firedAt DESC',
      limit: limit,
    );
    return rows
        .map((r) => PredictionEvent.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  // ------------------------------------------------------------------- care (v3)
  //
  // All of these are plain upsert/query pairs over the v3 tables. Deletes are
  // real deletes only where the user's intent is «remove this» (a contact, a
  // diary entry); a revoked consent is kept as a row with `revokedAt` set so the
  // access log in §4.3 stays honest about what used to be visible.

  Future<void> upsertEmergencyContact(EmergencyContact c) async {
    final db = await database;
    await db.insert(
      'emergency_contacts',
      c.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<EmergencyContact>> emergencyContactsFor(
    String patientId, {
    String? serverOrigin,
  }) async {
    final db = await database;
    final where = serverOrigin != null && serverOrigin.isNotEmpty
        ? 'patientId = ? AND (serverOrigin = ? OR serverOrigin = \'\')'
        : 'patientId = ?';
    final whereArgs = serverOrigin != null && serverOrigin.isNotEmpty
        ? [patientId, serverOrigin]
        : [patientId];
    final rows = await db.query(
      'emergency_contacts',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'priority ASC, name ASC',
    );
    return rows
        .map((r) => EmergencyContact.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> deleteEmergencyContact(
    String id, {
    String? patientId,
    String? serverOrigin,
  }) async {
    final db = await database;
    if (patientId != null && serverOrigin != null && serverOrigin.isNotEmpty) {
      await db.delete(
        'emergency_contacts',
        where: 'id = ? AND patientId = ? AND serverOrigin = ?',
        whereArgs: [id, patientId, serverOrigin],
      );
    } else if (patientId != null) {
      await db.delete(
        'emergency_contacts',
        where: 'id = ? AND patientId = ?',
        whereArgs: [id, patientId],
      );
    } else {
      await db.delete('emergency_contacts', where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<void> upsertMedicalCard(MedicalCard card, {String? serverOrigin}) async {
    final db = await database;
    final map = card.toMap();
    if (serverOrigin != null && serverOrigin.isNotEmpty) {
      map['serverOrigin'] = serverOrigin;
    }
    await db.insert(
      'medical_card',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<MedicalCard?> medicalCardFor(
    String patientId, {
    String? serverOrigin,
  }) async {
    final db = await database;
    final where = serverOrigin != null && serverOrigin.isNotEmpty
        ? 'patientId = ? AND (serverOrigin = ? OR serverOrigin = \'\')'
        : 'patientId = ?';
    final whereArgs = serverOrigin != null && serverOrigin.isNotEmpty
        ? [patientId, serverOrigin]
        : [patientId];
    final rows = await db.query(
      'medical_card',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'updatedAt DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MedicalCard.fromMap(Map<String, dynamic>.from(rows.first));
  }

  Future<void> insertTrigger(TriggerEntry t) async {
    final db = await database;
    await db.insert(
      'trigger_entries',
      t.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<TriggerEntry>> triggersFor(
    String patientId, {
    DateTime? since,
    int limit = 200,
    String? serverOrigin,
  }) async {
    final db = await database;
    var where = since == null
        ? 'patientId = ?'
        : 'patientId = ? AND occurredAt >= ?';
    final whereArgs = since == null
        ? <Object?>[patientId]
        : <Object?>[patientId, since.toIso8601String()];
    if (serverOrigin != null && serverOrigin.isNotEmpty) {
      where = '$where AND serverOrigin = ?';
      whereArgs.add(serverOrigin);
    }
    final rows = await db.query(
      'trigger_entries',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'occurredAt DESC',
      limit: limit,
    );
    return rows
        .map((r) => TriggerEntry.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> deleteTrigger(
    String id, {
    String? patientId,
    String? serverOrigin,
  }) async {
    final db = await database;
    if (patientId != null && serverOrigin != null && serverOrigin.isNotEmpty) {
      await db.delete(
        'trigger_entries',
        where: 'id = ? AND patientId = ? AND serverOrigin = ?',
        whereArgs: [id, patientId, serverOrigin],
      );
    } else if (patientId != null) {
      await db.delete(
        'trigger_entries',
        where: 'id = ? AND patientId = ?',
        whereArgs: [id, patientId],
      );
    } else {
      await db.delete('trigger_entries', where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<void> upsertConsent(CaregiverConsent c) async {
    final db = await database;
    await db.insert(
      'consents',
      c.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<CaregiverConsent>> consentsFor(
    String patientId, {
    bool activeOnly = false,
    String? serverOrigin,
  }) async {
    final db = await database;
    var where = activeOnly
        ? 'patientId = ? AND revokedAt IS NULL'
        : 'patientId = ?';
    final whereArgs = <Object?>[patientId];
    if (serverOrigin != null && serverOrigin.isNotEmpty) {
      where = '$where AND serverOrigin = ?';
      whereArgs.add(serverOrigin);
    }
    final rows = await db.query(
      'consents',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'grantedAt DESC',
    );
    return rows
        .map((r) => CaregiverConsent.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> insertAccessLog(AccessLogEntry e) async {
    final db = await database;
    await db.insert(
      'access_log',
      e.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AccessLogEntry>> accessLogFor(
    String patientId, {
    int limit = 100,
    String? serverOrigin,
  }) async {
    final db = await database;
    final where = serverOrigin != null && serverOrigin.isNotEmpty
        ? 'patientId = ? AND (serverOrigin = ? OR serverOrigin = \'\')'
        : 'patientId = ?';
    final whereArgs = serverOrigin != null && serverOrigin.isNotEmpty
        ? [patientId, serverOrigin]
        : [patientId];
    final rows = await db.query(
      'access_log',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'at DESC',
      limit: limit,
    );
    return rows
        .map((r) => AccessLogEntry.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> upsertSeizureLog(SeizureLog s) async {
    final db = await database;
    await db.insert(
      'seizure_logs',
      s.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<SeizureLog>> seizureLogsFor(
    String patientId, {
    DateTime? since,
    int limit = 200,
    String? serverOrigin,
  }) async {
    final db = await database;
    var where = since == null
        ? 'patientId = ?'
        : 'patientId = ? AND occurredAt >= ?';
    final whereArgs = since == null
        ? <Object?>[patientId]
        : <Object?>[patientId, since.toIso8601String()];
    if (serverOrigin != null && serverOrigin.isNotEmpty) {
      where = '$where AND serverOrigin = ?';
      whereArgs.add(serverOrigin);
    }
    final rows = await db.query(
      'seizure_logs',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'occurredAt DESC',
      limit: limit,
    );
    return rows
        .map((r) => SeizureLog.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> upsertAdjudication(Adjudication a) async {
    final db = await database;
    await db.insert(
      'adjudications',
      a.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Adjudication>> adjudicationsFor(
    String patientId, {
    int limit = 200,
    String? serverOrigin,
  }) async {
    final db = await database;
    final where = serverOrigin != null && serverOrigin.isNotEmpty
        ? 'patientId = ? AND (serverOrigin = ? OR serverOrigin = \'\')'
        : 'patientId = ?';
    final whereArgs = serverOrigin != null && serverOrigin.isNotEmpty
        ? [patientId, serverOrigin]
        : [patientId];
    final rows = await db.query(
      'adjudications',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'decidedAt DESC',
      limit: limit,
    );
    return rows
        .map((r) => Adjudication.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  /// Every alert id under [patientId] that already carries a verdict — used to
  /// show the doctor only what still needs review (§5.4).
  Future<Set<String>> adjudicatedAlertIds(
    String patientId, {
    String? serverOrigin,
  }) async {
    final db = await database;
    final where = serverOrigin != null && serverOrigin.isNotEmpty
        ? 'patientId = ? AND (serverOrigin = ? OR serverOrigin = \'\')'
        : 'patientId = ?';
    final whereArgs = serverOrigin != null && serverOrigin.isNotEmpty
        ? [patientId, serverOrigin]
        : [patientId];
    final rows = await db.query(
      'adjudications',
      columns: ['alertId'],
      where: where,
      whereArgs: whereArgs,
    );
    return rows.map((r) => r['alertId'] as String).toSet();
  }

  Future<void> upsertAlertResponse(AlertResponse r) async {
    final db = await database;
    await db.insert(
      'alert_responses',
      r.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AlertResponse>> alertResponsesFor(
    String alertId, {
    String? serverOrigin,
  }) async {
    final db = await database;
    final where = serverOrigin != null && serverOrigin.isNotEmpty
        ? 'alertId = ? AND serverOrigin = ?'
        : 'alertId = ?';
    final whereArgs = serverOrigin != null && serverOrigin.isNotEmpty
        ? [alertId, serverOrigin]
        : [alertId];
    final rows = await db.query(
      'alert_responses',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'at ASC',
    );
    return rows
        .map((r) => AlertResponse.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> upsertClinicalNote(ClinicalNote n) async {
    final db = await database;
    await db.insert(
      'clinical_notes',
      n.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ClinicalNote>> clinicalNotesFor(
    String patientId, {
    int limit = 100,
    String? serverOrigin,
  }) async {
    final db = await database;
    final where = serverOrigin != null && serverOrigin.isNotEmpty
        ? 'patientId = ? AND (serverOrigin = ? OR serverOrigin = \'\')'
        : 'patientId = ?';
    final whereArgs = serverOrigin != null && serverOrigin.isNotEmpty
        ? [patientId, serverOrigin]
        : [patientId];
    final rows = await db.query(
      'clinical_notes',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'writtenAt DESC',
      limit: limit,
    );
    return rows
        .map((r) => ClinicalNote.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  // ----------------------------------------------------------------- outbox (v3)

  /// Includes exhausted intents so they remain visible and block dependent writes.
  Future<List<OutboxItem>> careOutboxForOwner(String ownerId, {String? origin}) async {
    final db = await database;
    final rows = await db.query(
      'outbox',
      where: 'path != ?',
      whereArgs: ['/cloud/sync'],
      orderBy: 'createdAt ASC, rowid ASC',
    );
    return rows
        .map((row) => OutboxItem.fromMap(Map<String, dynamic>.from(row)))
        .where((item) =>
            item.body['_ownerId'] == ownerId &&
            (origin == null ||
                origin.isEmpty ||
                item.body['_ownerOrigin'] == origin))
        .toList();
  }

  Future<int> retryCareWrites({
    required String ownerId,
    required String origin,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      var reset = 0;
      final rows = await txn.query(
        'outbox',
        where: 'attempts > 0 AND path != ?',
        whereArgs: ['/cloud/sync'],
      );
      for (final row in rows) {
        final item = OutboxItem.fromMap(Map<String, dynamic>.from(row));
        if (item.body['_ownerId'] != ownerId ||
            item.body['_ownerOrigin'] != origin) {
          continue;
        }
        reset += await txn.update(
          'outbox',
          {'attempts': 0, 'lastError': null},
          where: 'id = ? AND body = ?',
          whereArgs: [item.id, row['body']],
        );
      }
      return reset;
    });
  }

  static const _careTables = {
    'emergency_contacts',
    'medical_card',
    'trigger_entries',
    'seizure_logs',
    'clinical_notes',
    'consents',
    'adjudications',
    'alert_responses',
  };

  static void _validateCareTable(String table) {
    if (!_careTables.contains(table)) {
      throw ArgumentError.value(table, 'table', 'Unsupported care table');
    }
  }

  static String? _carePatientId(OutboxItem item) {
    final parts = Uri.tryParse(item.path)?.pathSegments;
    if (parts == null || parts.length < 2 || parts.first != 'patients') {
      return null;
    }
    return parts[1].isEmpty ? null : parts[1];
  }

  /// Commit the visible local change and its durable delivery together. A
  /// duplicate delivery ID aborts the transaction instead of losing a write.
  Future<void> persistCareWrite({
    required OutboxItem item,
    String? table,
    Map<String, Object?>? row,
    String? deleteId,
    String? patientId,
  }) async {
    final metadataTable = item.body['_table'];
    if (metadataTable != null && metadataTable is! String) {
      throw ArgumentError('Invalid care table metadata');
    }
    final careTable = table ?? metadataTable as String?;
    if (careTable != null) {
      _validateCareTable(careTable);
    }
    if (table != null && metadataTable != null && table != metadataTable) {
      throw ArgumentError('Care table does not match delivery metadata');
    }
    if (row != null && deleteId != null) {
      throw ArgumentError('A care write cannot both save and delete');
    }
    if ((row != null || deleteId != null) && careTable == null) {
      throw ArgumentError('A care change requires a table');
    }
    if (deleteId != null && (patientId == null || patientId.isEmpty)) {
      throw ArgumentError('A care deletion requires an explicit patientId');
    }
    final rowPatient = row?['patientId'];
    if (row != null && (rowPatient is! String || rowPatient.isEmpty)) {
      throw ArgumentError('A care row requires a patientId');
    }
    final scopedPatient = patientId ?? rowPatient as String?;
    if (scopedPatient != null &&
        (_carePatientId(item) != scopedPatient ||
            (row != null && rowPatient != scopedPatient))) {
      throw ArgumentError('Care patient does not match delivery path');
    }
    final rowId =
        deleteId ??
        (careTable == 'medical_card' ? rowPatient : row?['id']) ??
        item.body['_rowId'];
    if (careTable != null && (rowId is! String || rowId.isEmpty)) {
      throw ArgumentError('A care delivery requires a row ID');
    }
    if (item.body['_rowId'] != null && item.body['_rowId'] != rowId) {
      throw ArgumentError('Care row does not match delivery metadata');
    }
    final origin = (item.body['_ownerOrigin'] as String?) ??
        (row?['serverOrigin'] as String?) ??
        '';
    final delivery = item.toMap();
    delivery['body'] = jsonEncode({
      ...item.body,
      '_table': ?careTable,
      '_rowId': ?rowId,
      if (origin.isNotEmpty) '_ownerOrigin': origin,
    });
    final db = await database;
    await db.transaction((txn) async {
      if (row != null) {
        final key = careTable == 'medical_card' ? 'patientId' : 'id';
        final queryWhere = careTable == 'medical_card' && origin.isNotEmpty
            ? 'patientId = ? AND serverOrigin = ?'
            : '$key = ?';
        final queryArgs = careTable == 'medical_card' && origin.isNotEmpty
            ? [scopedPatient, origin]
            : [rowId];
        final existing = await txn.query(
          careTable!,
          columns: ['patientId'],
          where: queryWhere,
          whereArgs: queryArgs,
          limit: 1,
        );
        if (existing.isNotEmpty &&
            existing.first['patientId'] != scopedPatient) {
          throw StateError('Care row belongs to another patient');
        }
        await txn.insert(careTable, {
          ...row,
          'synced': 0,
          if (origin.isNotEmpty) 'serverOrigin': origin,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } else if (deleteId != null) {
        final key = careTable == 'medical_card' ? 'patientId' : 'id';
        final delWhere = origin.isNotEmpty
            ? '$key = ? AND patientId = ? AND (serverOrigin = ? OR serverOrigin = \'\')'
            : '$key = ? AND patientId = ?';
        final delArgs = origin.isNotEmpty
            ? [deleteId, scopedPatient, origin]
            : [deleteId, scopedPatient];
        await txn.delete(
          careTable!,
          where: delWhere,
          whereArgs: delArgs,
        );
      }
      await txn.insert(
        'outbox',
        delivery,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    });
  }

  /// Remove only this accepted delivery. A newer queued edit (even exhausted)
  /// keeps the current local row unsynced until that edit is accepted as well.
  Future<void> acknowledgeCareWrite(OutboxItem item) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'outbox',
        where: 'id = ?',
        whereArgs: [item.id],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }
      final stored = OutboxItem.fromMap(Map<String, dynamic>.from(rows.single));
      if (stored.method != item.method ||
          stored.path != item.path ||
          jsonEncode(stored.body) != jsonEncode(item.body) ||
          stored.createdAt != item.createdAt) {
        throw StateError('Delivery changed before acknowledgment');
      }
      final table = stored.body['_table'];
      final rowId = stored.body['_rowId'];
      if (table != null) {
        if (table is! String || rowId is! String || rowId.isEmpty) {
          throw StateError('Invalid care delivery metadata');
        }
        _validateCareTable(table);
      }
      await txn.delete('outbox', where: 'id = ?', whereArgs: [item.id]);
      if (table == null) {
        return;
      }
      final patient = _carePatientId(stored);
      if (patient == null) {
        return;
      }
      final remaining = await txn.query('outbox', columns: ['body', 'path']);
      for (final pending in remaining) {
        final body = jsonDecode(pending['body'] as String);
        if (body is! Map) {
          return; // Unknown pending state cannot prove delivery.
        }
        if (body['_table'] == table &&
            body['_rowId'] == rowId &&
            body['_ownerId'] == stored.body['_ownerId'] &&
            body['_ownerOrigin'] == stored.body['_ownerOrigin']) {
          return;
        }
      }
      final origin = stored.body['_ownerOrigin'] as String?;
      final ackWhere = table == 'medical_card'
          ? (origin != null && origin.isNotEmpty
              ? 'patientId = ? AND serverOrigin = ?'
              : 'patientId = ?')
          : (origin != null && origin.isNotEmpty
              ? 'id = ? AND patientId = ? AND serverOrigin = ?'
              : 'id = ? AND patientId = ?');
      final ackArgs = table == 'medical_card'
          ? (origin != null && origin.isNotEmpty ? [patient, origin] : [patient])
          : (origin != null && origin.isNotEmpty
              ? [rowId, patient, origin]
              : [rowId, patient]);
      await txn.update(
        table as String,
        {'synced': 1},
        where: ackWhere,
        whereArgs: ackArgs,
      );
    });
  }

  /// Tombstones stay protective after retry exhaustion. A stale remote read
  /// must not resurrect a local deletion awaiting this owner's server.
  Future<Set<String>> queuedCareDeletes({
    required String patientId,
    required String ownerId,
    required String origin,
  }) async {
    final db = await database;
    final rows = await db.query(
      'outbox',
      columns: ['path', 'body'],
      where: 'UPPER(method) = ?',
      whereArgs: ['DELETE'],
    );
    final prefix = '/patients/$patientId/';
    final paths = <String>{};
    for (final row in rows) {
      final path = row['path'] as String;
      if (!path.startsWith(prefix)) {
        continue;
      }
      final body = jsonDecode(row['body'] as String);
      if (body is Map &&
          body['_ownerId'] == ownerId &&
          body['_ownerOrigin'] == origin) {
        paths.add(path);
      }
    }
    return paths;
  }

  /// Apply a remote deletion only to a delivered cached row. Local unsent
  /// edits retain their outbox state for reconciliation instead of disappearing.
  Future<void> removeSyncedCareRows({
    required String table,
    required String patientId,
    required List<String> ids,
    String? serverOrigin,
  }) async {
    if (table != 'emergency_contacts' && table != 'trigger_entries') {
      throw ArgumentError.value(table, 'table', 'Unsupported deletion table');
    }
    if (patientId.isEmpty) {
      throw ArgumentError('A patientId is required');
    }
    final unique = ids.toSet().toList();
    if (unique.isEmpty) {
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      for (var start = 0; start < unique.length; start += 200) {
        final end = start + 200 < unique.length ? start + 200 : unique.length;
        final chunk = unique.sublist(start, end);
        final inClause = List.filled(chunk.length, '?').join(',');
        final where = serverOrigin != null && serverOrigin.isNotEmpty
            ? 'patientId = ? AND synced = 1 AND serverOrigin = ? AND id IN ($inClause)'
            : 'patientId = ? AND synced = 1 AND id IN ($inClause)';
        final whereArgs = serverOrigin != null && serverOrigin.isNotEmpty
            ? [patientId, serverOrigin, ...chunk]
            : [patientId, ...chunk];
        await txn.delete(
          table,
          where: where,
          whereArgs: whereArgs,
        );
      }
    });
  }

  Future<void> enqueueOutbox(OutboxItem item) async {
    final db = await database;
    await db.insert(
      'outbox',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Oldest first: writes replay in the order the user made them, so a create
  /// can never be applied after the update that followed it.
  Future<List<OutboxItem>> pendingOutbox({
    int limit = 100,
    String? onlyPath,
    String? excludePath,
    String? ownerId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'outbox',
      where:
          'attempts < ?${onlyPath != null ? ' AND path = ?' : ''}${excludePath != null ? ' AND path != ?' : ''}',
      whereArgs: [OutboxItem.maxAttempts, ?onlyPath, ?excludePath],
      orderBy: 'createdAt ASC',
      limit: ownerId == null ? limit : null,
    );
    return rows
        .map((r) => OutboxItem.fromMap(Map<String, dynamic>.from(r)))
        .where((item) => ownerId == null || item.body['_ownerId'] == ownerId)
        .take(limit)
        .toList();
  }

  Future<int> pendingOutboxCount() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM outbox WHERE attempts < ?',
      [OutboxItem.maxAttempts],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  Future<void> deleteOutbox(String id) async {
    final db = await database;
    await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> bumpOutboxAttempt(String id, String? error) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE outbox SET attempts = attempts + 1, lastError = ? WHERE id = ?',
      [error, id],
    );
  }

  /// Mark a locally-created row as delivered. [table] is always one of the v3
  /// care tables; the call sites pass a constant, never user input.
  Future<void> markCareSynced(String table, String id) async {
    _validateCareTable(table);
    final db = await database;
    await db.update(
      table,
      {'synced': 1},
      where: table == 'medical_card' ? 'patientId = ?' : 'id = ?',
      whereArgs: [id],
    );
  }

  // ---------------------------------------------------------------------------
  // v4: Messages
  // ---------------------------------------------------------------------------

  Future<void> _createV4Tables(Database db) async {
    await db.execute('''
          CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            patientId TEXT NOT NULL,
            senderId TEXT NOT NULL,
            senderName TEXT NOT NULL,
            senderRole TEXT NOT NULL,
            channelType TEXT NOT NULL,
            content TEXT NOT NULL,
            createdAt TEXT NOT NULL,
            readAt TEXT,
            synced INTEGER NOT NULL DEFAULT 0,
            serverOrigin TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ix_local_messages_patient_channel ON messages(patientId, channelType)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ix_local_messages_patient_origin ON messages(patientId, serverOrigin)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ix_local_messages_created_at ON messages(createdAt)',
    );
  }

  Future<void> insertMessage(ChatMessage msg) async {
    final db = await database;
    await db.insert(
      'messages',
      msg.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ChatMessage>> messagesForChannel(
    String patientId,
    String channelType, {
    int limit = 100,
    String? serverOrigin,
  }) async {
    final db = await database;
    final where = serverOrigin != null && serverOrigin.isNotEmpty
        ? 'patientId = ? AND channelType = ? AND serverOrigin = ?'
        : 'patientId = ? AND channelType = ?';
    final whereArgs = serverOrigin != null && serverOrigin.isNotEmpty
        ? [patientId, channelType, serverOrigin]
        : [patientId, channelType];
    final rows = await db.query(
      'messages',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'createdAt DESC, id DESC',
      limit: limit,
    );
    return rows.reversed
        .map((r) => ChatMessage.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<List<ChatMessage>> unsyncedMessages(String senderId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'synced = 0 AND senderId = ?',
      whereArgs: [senderId],
      orderBy: 'createdAt ASC',
      limit: 50,
    );
    return rows
        .map((r) => ChatMessage.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> replacePendingMessage(
    String id,
    ChatMessage serverMessage,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
      await txn.insert(
        'messages',
        serverMessage.copyWith(synced: true).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // v7: Offline Encrypted Credentials
  // ---------------------------------------------------------------------------

  Future<void> _createV7Tables(Database db) async {
    await db.execute('''
          CREATE TABLE IF NOT EXISTS user_credentials (
            username TEXT NOT NULL,
            serverOrigin TEXT NOT NULL,
            passwordHash TEXT NOT NULL,
            salt TEXT NOT NULL,
            userProfile TEXT NOT NULL,
            role TEXT NOT NULL,
            userId TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            PRIMARY KEY (username, serverOrigin)
          )
        ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ix_user_credentials_username ON user_credentials(username)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ix_user_credentials_origin ON user_credentials(serverOrigin)',
    );
  }

  Future<void> saveUserCredentials({
    required String username,
    required String serverOrigin,
    required String passwordHash,
    required String salt,
    required String userProfile,
    required String role,
    required String userId,
    required String updatedAt,
  }) async {
    final db = await database;
    await db.insert('user_credentials', {
      'username': username,
      'serverOrigin': serverOrigin,
      'passwordHash': passwordHash,
      'salt': salt,
      'userProfile': userProfile,
      'role': role,
      'userId': userId,
      'updatedAt': updatedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getUserCredentials({
    required String username,
    required String serverOrigin,
  }) async {
    final db = await database;
    final rows = await db.query(
      'user_credentials',
      where: 'username = ? AND serverOrigin = ?',
      whereArgs: [username, serverOrigin],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return Map<String, dynamic>.from(rows.first);
    }
    // Fallback matching: normalized trailing slashes and case-insensitive username
    final normalizedOrigin = serverOrigin.replaceAll(RegExp(r'/+$'), '');
    final altRows = await db.query(
      'user_credentials',
      where: 'LOWER(username) = LOWER(?)',
      whereArgs: [username.trim()],
    );
    for (final r in altRows) {
      final origin = (r['serverOrigin'] as String?)?.replaceAll(RegExp(r'/+$'), '');
      if (origin == normalizedOrigin) {
        return Map<String, dynamic>.from(r);
      }
    }
    return null;
  }
}
