import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/core/errors/failure.dart';
import 'package:epilepsy_monitor/core/utils/doctor_title_formatter.dart';
import 'package:epilepsy_monitor/core/utils/username_generator.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Phase 4: UsernameGenerator & DoctorTitleFormatter', () {
    test('transliterates Arabic names into clean Latin username slugs', () {
      expect(
        UsernameGenerator.generate('د. خالد العمري', prefix: 'dr'),
        'dr_khald_alamry',
      );
      expect(
        UsernameGenerator.generate('أحمد محمود', prefix: 'pat'),
        'pat_ahmd_mhmwd',
      );
      expect(
        UsernameGenerator.generate('سارة محمود', prefix: 'cg'),
        'cg_sarh_mhmwd',
      );
    });

    test('DoctorTitleFormatter applies idempotent doctor honorifics', () {
      expect(
        DoctorTitleFormatter.format('مطهر', role: UserRole.doctor),
        'د. مطهر',
      );
      expect(
        DoctorTitleFormatter.format('د. مطهر', role: UserRole.doctor),
        'د. مطهر',
      );
      expect(
        DoctorTitleFormatter.format('الدكتور خالد العمري', role: UserRole.doctor),
        'د. خالد العمري',
      );
      expect(
        DoctorTitleFormatter.formatWithRole(
          'مطهر',
          'طبيب',
          role: UserRole.doctor,
        ),
        'د. مطهر (طبيب)',
      );
      expect(
        DoctorTitleFormatter.formatWithRole(
          'أحمد محمود',
          'مريض',
          role: UserRole.patient,
        ),
        'أحمد محمود (مريض)',
      );
    });

    test('AppUser.sameSessionOwner preserves session identity across immutable copies', () {
      final beforeAdd = AppUser(
        uid: 'doc-1',
        name: 'د. مطهر',
        email: 'doc@epilepsy.local',
        role: UserRole.doctor,
        linkedPatientIds: const ['p1'],
      );
      final afterAdd = beforeAdd.copyWith(linkedPatientIds: const ['p1', 'p2']);

      expect(identical(beforeAdd, afterAdd), isFalse);
      expect(AppUser.sameSessionOwner(beforeAdd, afterAdd), isTrue);
      expect(AppUser.sameSessionOwner(null, null), isTrue);
      expect(AppUser.sameSessionOwner(beforeAdd, null), isFalse);
    });

    test('HTTP 409 maps to FailureKind.conflict', () {
      final failure = Failure.from(
        ApiException('username already exists', statusCode: 409),
      );
      expect(failure.kind, FailureKind.conflict);
      expect(failure.canRetry, isFalse);
    });
  });
}
