import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/features/doctor/doctor_home_screen.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'redesign_navigation_test.dart' show harness;

class PatientFormState extends AppState {
  int requests = 0;
  @override
  Future<PatientProfile> createDoctorPatient({
    required String name,
    required String username,
    String? password,
    String? phone,
    int? age,
    String? diagnosis,
    String? notes,
    String? caregiverName,
    String? caregiverUsername,
    String? caregiverPhone,
    String? caregiverRelation,
    String? caregiverPassword,
  }) async {
    requests++;
    return PatientProfile(patientId: 'test-patient', name: name);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final size in [const Size(360, 740), const Size(1440, 800)]) {
    testWidgets('patient form validates and confirms creation at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = PatientFormState();
      bool? result;
      await tester.pumpWidget(
        harness(
          app,
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => const AddPatientDialog(),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
          scale: 1.5,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ExpansionTile), findsOneWidget);
      final name = find.widgetWithText(TextFormField, 'اسم المريض الكامل *');
      final username = find.widgetWithText(TextFormField, 'اسم المستخدم *');
      final password = find.widgetWithText(
        TextFormField,
        'كلمة مرور المريض (اختيارية)',
      );
      await tester.enterText(name, 'Test Patient');
      await tester.ensureVisible(username);
      await tester.enterText(username, 'test_patient');
      await tester.ensureVisible(password);
      await tester.enterText(password, '123');
      await tester.ensureVisible(find.text('حفظ وإنشاء السجل'));
      await tester.tap(find.text('حفظ وإنشاء السجل'));
      await tester.pumpAndSettle();
      expect(app.requests, 0);
      await tester.ensureVisible(password);
      await tester.enterText(password, 'test-password-123');
      for (final entry in {
        'رقم هاتف المريض': '+967771234567',
        'العمر': '30',
        'التشخيص ونوع الصرع': 'Test diagnosis',
        'رقم اتصال الطوارئ *': '+967771234568',
      }.entries) {
        final field = find.widgetWithText(TextFormField, entry.key);
        await tester.ensureVisible(field);
        await tester.enterText(field, entry.value);
      }
      final gender = find.byType(DropdownButtonFormField<String>).first;
      await tester.ensureVisible(gender);
      await tester.tap(gender);
      await tester.pumpAndSettle();
      await tester.tap(find.text('أنثى').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('حفظ وإنشاء السجل'));
      await tester.tap(find.text('حفظ وإنشاء السجل'));
      await tester.pumpAndSettle();
      expect(app.requests, 1);
      expect(find.text('تم إنشاء ملف المريض بنجاح'), findsOneWidget);
      expect(result, isNull);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('تم'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.text('Open'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });
  }
}
