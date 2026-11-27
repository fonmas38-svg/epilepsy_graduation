import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/signal_simulator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('SeizureCycleController scenarios', () {
    test('live virtual device stays at baseline without a scenario', () {
      final c = SeizureCycleController(autoCycle: false);
      for (var i = 0; i < 30; i++) {
        expect(c.advance(), RiskLabel.stable);
      }
      expect(c.scenarioActive, isFalse);
    });

    test('critical scenario runs onset, ictal and recovery, then ends', () {
      final c = SeizureCycleController(autoCycle: false)
        ..startScenario(ScenarioLevel.critical);
      final phases = <SeizurePhase>[];
      final labels = <RiskLabel>[];
      while (c.scenarioActive) {
        phases.add(c.currentPhase);
        labels.add(c.advance());
      }
      expect(phases.first, SeizurePhase.preIctal);
      expect(phases.where((p) => p == SeizurePhase.ictal).length, 6);
      expect(phases.last, SeizurePhase.postIctal);
      expect(labels.where((l) => l == RiskLabel.highRisk).length, 6);
      expect(c.advance(), RiskLabel.stable);
    });

    test('stable level clears a running scenario', () {
      final c = SeizureCycleController(autoCycle: false)
        ..startScenario(ScenarioLevel.preIctal)
        ..advance()
        ..startScenario(ScenarioLevel.stable);
      expect(c.scenarioActive, isFalse);
      expect(c.advance(), RiskLabel.stable);
    });
  });

  test('v11 migration rewrites offset-less local timestamps as UTC', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE assessments (id TEXT, timestamp TEXT NOT NULL)',
    );
    final local = DateTime(2026, 3, 1, 17, 0, 0);
    final utc = DateTime.utc(2026, 3, 1, 15, 0, 0);
    await db.insert('assessments', {
      'id': 'local',
      'timestamp': local.toIso8601String(),
    });
    await db.insert('assessments', {
      'id': 'utc',
      'timestamp': utc.toIso8601String(),
    });

    await LocalDatabase.normalizeTimestampsToUtc(db);

    final rows = await db.query('assessments', orderBy: 'timestamp DESC');
    for (final row in rows) {
      expect((row['timestamp'] as String).endsWith('Z'), isTrue);
    }
    final migrated = rows.firstWhere((r) => r['id'] == 'local');
    expect(DateTime.parse(migrated['timestamp'] as String), local.toUtc());
    // Text order now matches real time order.
    final newestFirst = rows.map((r) => r['id']).toList();
    final expected = local.toUtc().isAfter(utc)
        ? ['local', 'utc']
        : ['utc', 'local'];
    expect(newestFirst, expected);
    await db.close();
  });
}
