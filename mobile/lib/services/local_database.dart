import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../core/config.dart';
import '../core/enums.dart';
import '../models/models.dart';
import 'secure_store.dart';
import 'signal_simulator.dart';

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
  static final LocalDatabase instance = LocalDatabase._();

  Database? _db;
  static const _kDbKey = 'local_db_encryption_key';

  /// Schema version. v1 = readings/assessments/alerts. v2 = + medication
  /// adherence (medications, medication_logs) and prediction_events. Bumping
  /// this triggers [_onUpgrade], which only CREATEs new tables — existing tables
  /// are never altered, so no patient data is touched.
  static const _dbVersion = 2;

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
    final key = await SecureStore.instance.readOrCreateSecret(_kDbKey, byteLength: 32);
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
            synced INTEGER NOT NULL DEFAULT 0
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
            processingMs REAL NOT NULL
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
            acknowledgedBy TEXT
          )
        ''');
    // v2 tables are created here for fresh installs and in _onUpgrade for
    // existing ones. Same idempotent DDL is used in both paths.
    await _createV2Tables(db);
  }

  /// Additive migrations. Only ever CREATE new tables — never ALTER or DROP the
  /// existing readings/assessments/alerts, so upgrades cannot lose data.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createV2Tables(db);
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
            createdAt TEXT NOT NULL
          )
        ''');
    await db.execute('''
          CREATE TABLE IF NOT EXISTS medication_logs (
            id TEXT PRIMARY KEY,
            medicationId TEXT NOT NULL,
            patientId TEXT NOT NULL,
            scheduledFor TEXT NOT NULL,
            takenAt TEXT,
            status TEXT NOT NULL DEFAULT 'taken'
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
            outcome TEXT NOT NULL
          )
        ''');
  }

  Future<void> insertReading(VitalReading reading) async {
    final db = await database;
    await db.insert(
      'readings',
      {
        'id': reading.id,
        'patientId': reading.patientId,
        'timestamp': reading.timestamp.toIso8601String(),
        'eeg': encodeSignal(reading.eeg),
        'ecg': encodeSignal(reading.ecg),
        'motion': encodeSignal(reading.motion),
        'hr': reading.hr,
        'synced': reading.synced ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _pruneOld(db, reading.patientId);
  }

  Future<void> _pruneOld(Database db, String patientId) async {
    final cutoff = DateTime.now().subtract(AppConfig.localRetention).toIso8601String();
    await db.delete(
      'readings',
      where: 'patientId = ? AND timestamp < ?',
      whereArgs: [patientId, cutoff],
    );
  }

  Future<List<VitalReading>> recentReadings(String patientId, {int limit = 120}) async {
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

  Future<void> insertAssessment(RiskAssessment a) async {
    final db = await database;
    await db.insert(
      'assessments',
      {
        'id': a.id,
        'patientId': a.patientId,
        'timestamp': a.timestamp.toIso8601String(),
        'label': a.label.apiValue,
        'confidence': a.confidence,
        'features': jsonEncode(a.features),
        'processingMs': a.processingMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
      features: Map<String, dynamic>.from(jsonDecode(r['features'] as String) as Map),
      processingMs: (r['processingMs'] as num).toDouble(),
    );
  }

  Future<List<RiskAssessment>> assessmentsFor(String patientId, {int limit = 100}) async {
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
            features: Map<String, dynamic>.from(jsonDecode(r['features'] as String) as Map),
            processingMs: (r['processingMs'] as num).toDouble(),
          ),
        )
        .toList();
  }

  Future<void> insertAlert(AlertItem alert) async {
    final db = await database;
    await db.insert(
      'alerts',
      {
        'id': alert.id,
        'patientId': alert.patientId,
        'timestamp': alert.timestamp.toIso8601String(),
        'severity': alert.severity,
        'message': alert.message,
        'recipients': jsonEncode(alert.recipients),
        'acknowledged': alert.acknowledged ? 1 : 0,
        'acknowledgedBy': alert.acknowledgedBy,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
            recipients: List<String>.from(jsonDecode(r['recipients'] as String) as List),
            acknowledged: (r['acknowledged'] as int) == 1,
            acknowledgedBy: r['acknowledgedBy'] as String?,
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
    await db.insert(
      'medications',
      {
        'id': m.id,
        'patientId': m.patientId,
        'name': m.name,
        'dosage': m.dosage,
        'schedule': m.schedule,
        'times': jsonEncode(m.times),
        'active': m.active ? 1 : 0,
        'createdAt': m.createdAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Medication>> medicationsFor(String patientId, {bool activeOnly = false}) async {
    final db = await database;
    final rows = await db.query(
      'medications',
      where: activeOnly ? 'patientId = ? AND active = 1' : 'patientId = ?',
      whereArgs: [patientId],
      orderBy: 'createdAt DESC',
    );
    return rows
        .map((r) => Medication(
              id: r['id'] as String,
              patientId: r['patientId'] as String,
              name: r['name'] as String,
              dosage: r['dosage'] as String? ?? '',
              schedule: r['schedule'] as String? ?? '',
              times: List<String>.from(jsonDecode(r['times'] as String? ?? '[]') as List),
              active: (r['active'] as int? ?? 1) == 1,
              createdAt: DateTime.tryParse(r['createdAt'] as String? ?? '') ?? DateTime.now(),
            ))
        .toList();
  }

  Future<void> setMedicationActive(String id, bool active) async {
    final db = await database;
    await db.update('medications', {'active': active ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMedication(String id) async {
    final db = await database;
    await db.delete('medications', where: 'id = ?', whereArgs: [id]);
    await db.delete('medication_logs', where: 'medicationId = ?', whereArgs: [id]);
  }

  Future<void> insertMedicationLog(MedicationLog log) async {
    final db = await database;
    await db.insert('medication_logs', log.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<MedicationLog>> medicationLogsFor(String patientId, {DateTime? since}) async {
    final db = await database;
    final rows = await db.query(
      'medication_logs',
      where: since == null ? 'patientId = ?' : 'patientId = ? AND scheduledFor >= ?',
      whereArgs: since == null ? [patientId] : [patientId, since.toIso8601String()],
      orderBy: 'scheduledFor DESC',
    );
    return rows.map((r) => MedicationLog.fromMap(Map<String, dynamic>.from(r))).toList();
  }

  // --------------------------------------------------------- prediction events
  Future<void> insertPredictionEvent(PredictionEvent e) async {
    final db = await database;
    await db.insert('prediction_events', e.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<PredictionEvent>> predictionEventsFor(String patientId, {int limit = 100}) async {
    final db = await database;
    final rows = await db.query(
      'prediction_events',
      where: 'patientId = ?',
      whereArgs: [patientId],
      orderBy: 'firedAt DESC',
      limit: limit,
    );
    return rows.map((r) => PredictionEvent.fromMap(Map<String, dynamic>.from(r))).toList();
  }
}
