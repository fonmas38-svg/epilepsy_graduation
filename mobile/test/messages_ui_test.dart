import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/features/shared/clinical_messages_screen.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'message_session_test.dart' show MessageDb, MessageApi, message;
import 'redesign_navigation_test.dart' show harness;

Future<AppState> session(MessageDb db, {String role = 'patient'}) async {
  final state = AppState(database: db, apiClient: MessageApi());
  await state.auth.applyBackendSession({
    'user': {
      'id': role == 'patient' ? 'p1' : 'carer',
      'name': 'Account owner',
      'username': 'owner',
      'role': role,
    },
    'patients': [
      for (final id in ['p1', 'p2']) {'id': id, 'name': 'Patient $id'},
    ],
  });
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'draft is retained on local failure and saved messages use accurate pending text',
    (tester) async {
      final db = MessageDb();
      final state = await session(db);
      db.insert = (_) async => throw StateError('storage failed');
      await tester.pumpWidget(harness(state, const ClinicalMessagesScreen()));
      await tester.pumpAndSettle();
      final input = find.widgetWithText(TextField, 'اكتب رسالة');
      await tester.enterText(input, 'Keep this draft');
      await tester.tap(find.byTooltip('إرسال الرسالة'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Keep this draft',
      );
      expect(db.rows, isEmpty);
      db.insert = null;
      await tester.tap(find.byTooltip('إرسال الرسالة'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(db.rows.single.content, 'Keep this draft');
      expect(find.text('محفوظ محليًا · بانتظار الإرسال'), findsOneWidget);
      expect(find.text('تم التسليم'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
  testWidgets(
    'switching channels keeps separate drafts and filters private messages',
    (tester) async {
      final db = MessageDb()..rows.add(message('private', 'p1'));
      final state = await session(db);
      await tester.pumpWidget(harness(state, const ClinicalMessagesScreen()));
      await tester.pumpAndSettle();
      final input = find.widgetWithText(TextField, 'اكتب رسالة');
      await tester.enterText(input, 'Private draft');
      await tester.tap(find.text('دائرة الرعاية'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(find.text('Message private'), findsNothing);
      await tester.enterText(input, 'Family draft');
      await tester.tap(find.text('الطبيب والمريض'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, 'Private draft');
      expect(find.text('Message private'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
  for (final size in [const Size(320, 640), const Size(1440, 550)]) {
    testWidgets(
      'caregiver conversation is patient-scoped and responsive at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final db = MessageDb()
          ..rows.add(message('family-p2', 'p2', channel: 'family_patient'));
        final state = await session(db, role: 'caregiver');
        await tester.pumpWidget(
          harness(state, const ClinicalMessagesScreen(), scale: 1.5),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Patient p2'));
        await tester.pumpAndSettle();
        expect(find.text('Message family-p2'), findsOneWidget);
        expect(find.text('الطبيب والمريض'), findsNothing);
        expect(find.text('Account owner'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );
  }
}
