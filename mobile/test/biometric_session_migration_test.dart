import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/services/biometric_service.dart';

String credential(String? sid) {
  final claims = {
    'sub': 'p',
    'role': 'patient',
    'exp':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000,
    'sid': ?sid,
    'session_version': 0,
  };
  final token =
      'header.${base64Url.encode(utf8.encode(jsonEncode(claims)))}.signature';
  return jsonEncode({
    'token': token,
    'userId': 'p',
    'username': 'patient',
    'role': 'patient',
    'baseUrl': 'https://one.invalid',
  });
}

void main() {
  test(
    'legacy biometric credential without a registered session requires password login',
    () {
      expect(BiometricSession.parse(credential(null)), isNull);
      expect(BiometricSession.parse(credential('')), isNull);
    },
  );
  test('bound unexpired credential can proceed to server verification', () {
    final value = BiometricSession.parse(credential('registered-session'));
    expect(value?.userId, 'p');
    expect(value?.baseUrl, 'https://one.invalid');
  });
}
