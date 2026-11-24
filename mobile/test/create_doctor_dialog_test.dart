import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/features/admin/create_doctor_dialog.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'redesign_navigation_test.dart' show harness;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final language in ['ar', 'en']) {
    for (final width in [360.0, 1440.0]) {
      testWidgets(
        'doctor form preserves timeout draft and prevents duplicate sends $language $width',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final app = AppState();
          var requests = 0;
          bool? result;
          final completion = Completer<void>();
          await tester.pumpWidget(
            harness(
              app,
              Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await showDialog<bool>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => CreateDoctorDialog(
                          create:
                              ({
                                required name,
                                required username,
                                required password,
                                phone,
                              }) async {
                                requests++;
                                expect(name, 'Test Doctor');
                                expect(username, 'doctor_test');
                                expect(password, 'test-password-123');
                                if (requests == 1) {
                                  throw TimeoutException(
                                    'private transport detail',
                                  );
                                }
                                await completion.future;
                              },
                        ),
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
              locale: language,
              scale: 1.5,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final fields = find.byType(TextFormField);
          await tester.enterText(fields.at(0), 'Test Doctor');
          await tester.enterText(fields.at(1), 'doctor_test');
          await tester.ensureVisible(fields.at(2));
          await tester.enterText(fields.at(2), '123');
          final submit = find.text(
            language == 'ar' ? 'إنشاء الحساب' : 'Create account',
          );
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(requests, 0);
          await tester.ensureVisible(fields.at(2));
          await tester.enterText(fields.at(2), 'test-password-123');
          for (final entry in {
            3: '+967771234567',
            5: 'TEST-LICENSE',
            6: '1234567890',
            7: 'Neurology',
            8: 'Test hospital',
          }.entries) {
            await tester.ensureVisible(fields.at(entry.key));
            await tester.enterText(fields.at(entry.key), entry.value);
          }

          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(requests, 1);
          expect(result, isNull);
          expect(find.textContaining('private transport detail'), findsNothing);
          final nameField = tester.widget<TextFormField>(fields.at(0));
          expect(nameField.controller!.text, 'Test Doctor');
          expect(
            find.textContaining(
              language == 'ar' ? 'قد يكون الحساب' : 'may exist',
            ),
            findsOneWidget,
          );
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await tester.pump();
          await tester.tap(submit);
          await tester.pump();
          expect(requests, 2);
          expect(result, isNull);
          expect(
            tester
                .widget<TextField>(
                  find.descendant(
                    of: fields.at(0),
                    matching: find.byType(TextField),
                  ),
                )
                .readOnly,
            isTrue,
          );
          completion.complete();
          await tester.pumpAndSettle();
          expect(result, isTrue);
          expect(find.text('Open'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          app.dispose();
        },
      );
    }
  }
}
