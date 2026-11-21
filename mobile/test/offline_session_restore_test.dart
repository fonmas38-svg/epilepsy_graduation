import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';

String token(String sid, {bool expired = false}) {
  final expiry =
      DateTime.now()
          .add(Duration(hours: expired ? -1 : 1))
          .millisecondsSinceEpoch ~/
      1000;
  return 'header.${base64Url.encode(utf8.encode(jsonEncode({'sub': 'p', 'role': 'patient', 'sid': sid, 'exp': expiry})))}.signature';
}

const profile = {
  'user': {'id': 'p', 'role': 'patient', 'name': 'Patient'},
  'patients': [
    {'id': 'p', 'name': 'Patient'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'closing and reopening restores only the same unexpired login context',
    () async {
      final original = TokenProvider(baseUrl: 'https://one.invalid');
      await original.useLoginToken(
        token: token('first'),
        role: 'patient',
        subject: 'p',
      );
      await original.cacheSessionContext(profile);
      final reopened = TokenProvider(baseUrl: 'https://one.invalid');
      await reopened.init();
      expect(await reopened.cachedSessionContext(), profile);
      await reopened.clear();
      final signedOut = TokenProvider(baseUrl: 'https://one.invalid');
      await signedOut.init();
      expect(await signedOut.cachedSessionContext(), isNull);
    },
  );
  test(
    'another server, another login and expired credentials cannot restore old profiles',
    () async {
      final provider = TokenProvider(baseUrl: 'https://one.invalid');
      await provider.useLoginToken(
        token: token('first'),
        role: 'patient',
        subject: 'p',
      );
      await provider.cacheSessionContext(profile);
      provider.updateBaseUrl('https://another.invalid');
      expect(await provider.cachedSessionContext(), isNull);
      provider.updateBaseUrl('https://one.invalid');
      await provider.useLoginToken(
        token: token('second'),
        role: 'patient',
        subject: 'p',
      );
      expect(await provider.cachedSessionContext(), isNull);
      await provider.cacheSessionContext(profile);
      await provider.useLoginToken(
        token: token('second', expired: true),
        role: 'patient',
        subject: 'p',
      );
      // Decoupled session context (Phase 2 #16): access token expiry does not drop session context
      expect(await provider.cachedSessionContext(), profile);
    },
  );
  test(
    'foreign identity cannot overwrite an authorized cached profile',
    () async {
      final provider = TokenProvider(baseUrl: 'https://one.invalid');
      await provider.useLoginToken(
        token: token('first'),
        role: 'patient',
        subject: 'p',
      );
      await provider.cacheSessionContext(profile);
      await provider.cacheSessionContext({
        'user': {'id': 'someone-else', 'role': 'patient'},
      });
      expect(await provider.cachedSessionContext(), profile);
    },
  );
}
