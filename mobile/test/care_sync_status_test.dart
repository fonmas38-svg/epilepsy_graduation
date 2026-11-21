import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/core/errors/failure.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/widgets/care_sync_status_card.dart';
import 'care_outbox_test.dart' show QueueApi, QueueDb, item;
import 'redesign_navigation_test.dart' show harness;

class RetryDb extends QueueDb {
  int retries = 0;
  @override
  Future<int> retryCareWrites({
    required String ownerId,
    required String origin,
  }) async {
    retries++;
    var count = 0;
    for (var i = 0; i < items.length; i++) {
      final row = items[i];
      if (row.body['_ownerId'] != ownerId ||
          row.body['_ownerOrigin'] != origin) {
        continue;
      }
      items[i] = OutboxItem(
        id: row.id,
        method: row.method,
        path: row.path,
        body: row.body,
        createdAt: row.createdAt,
      );
      count++;
    }
    return count;
  }
}

void main() {
  for (final language in ['ar', 'en']) {
    testWidgets(
      'care delivery status confirms retry and retains foreign records $language',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 850));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final db = RetryDb()
          ..items.addAll([
            item(
              'failed',
              '/patients/p/triggers',
              attempts: OutboxItem.maxAttempts,
            ),
            item(
              'foreign',
              '/patients/p/triggers',
              origin: 'https://other.invalid',
              attempts: OutboxItem.maxAttempts,
            ),
          ]);
        final api = QueueApi()
          ..respond = (_) async => throw const Failure(FailureKind.offline);
        final app = AppState(database: db, apiClient: api);
        app.auth.currentUser = AppUser(
          uid: 'p',
          name: 'Patient',
          email: '',
          role: UserRole.patient,
        );
        await tester.pumpWidget(
          harness(
            app,
            const Scaffold(
              body: SingleChildScrollView(child: CareSyncStatusCard()),
            ),
            locale: language,
            scale: 1.5,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == 'ar' ? 'تعذر إرساله: 1' : 'Delivery stopped: 1',
          ),
          findsOneWidget,
        );
        final retryLabel = language == 'ar'
            ? 'إعادة المحاولة'
            : 'Retry delivery';
        await tester.tap(find.text(retryLabel));
        await tester.pumpAndSettle();
        await tester.tap(find.text(language == 'ar' ? 'إلغاء' : 'Cancel'));
        await tester.pumpAndSettle();
        expect(db.retries, 0);
        await tester.tap(find.text(retryLabel));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(language == 'ar' ? 'إعادة المحاولة' : 'Retry'),
          ),
        );
        await tester.pumpAndSettle();
        expect(db.retries, 1);
        expect(db.items.map((row) => row.id), ['failed', 'foreign']);
        expect(db.items.last.exhausted, isTrue);
        expect(
          find.text(
            language == 'ar' ? 'بانتظار الإرسال: 1' : 'Pending delivery: 1',
          ),
          findsOneWidget,
        );
        api.respond = null;
        await tester.tap(
          find.text(language == 'ar' ? 'مزامنة الآن' : 'Sync now'),
        );
        await tester.pumpAndSettle();
        expect(db.items.map((row) => row.id), ['foreign']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      },
    );
  }
}
