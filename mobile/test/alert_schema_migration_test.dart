import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:epilepsy_monitor/services/local_database.dart';

void main() {
  test(
    'alert upgrade preserves existing acknowledgment and is idempotent',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      try {
        await db.execute(
          'CREATE TABLE alerts (id TEXT PRIMARY KEY, acknowledged INTEGER, message TEXT)',
        );
        await db.insert('alerts', {
          'id': 'old',
          'acknowledged': 1,
          'message': 'existing',
        });
        await migrateAlertDetails(db);
        await migrateAlertDetails(db);
        final row = (await db.query('alerts')).single;
        expect(row['acknowledged'], 1);
        expect(row['message'], 'existing');
        expect(row['details'], '{}');
      } finally {
        await db.close();
      }
    },
  );
}
