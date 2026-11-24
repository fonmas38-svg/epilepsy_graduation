import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:epilepsy_monitor/core/errors/failure.dart';
import 'package:epilepsy_monitor/core/security/password_hasher.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/local_database.dart';

String mockJwt({
  String sub = 'user-1',
  String role = 'patient',
  String sid = 'sid-1',
}) {
  final exp =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  final header = base64Url.encode(
    utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})),
  );
  final payload = base64Url.encode(
    utf8.encode(jsonEncode({'sub': sub, 'role': role, 'sid': sid, 'exp': exp})),
  );
  return '$header.$payload.signature';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('Phase 2 R3: PasswordHasher Unit Tests', () {
    test('PBKDF2 SHA256 matches independent known-answer vectors', () {
      expect(
        PasswordHasher.hash('password', 'salt', rounds: 1),
        r'pbkdf2-sha256$1$120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
      expect(
        PasswordHasher.hash('password', 'salt', rounds: 2),
        r'pbkdf2-sha256$2$ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
      expect(
        PasswordHasher.verify('x', 'salt', r'pbkdf2-sha256$0$bad'),
        isFalse,
      );
      expect(
        PasswordHasher.verify('x', 'salt', r'pbkdf2-sha256$999999999$bad'),
        isFalse,
      );
      expect(PasswordHasher.needsRehash('legacy-hash'), isTrue);
      expect(PasswordHasher.needsRehash(r'pbkdf2-sha256$1000$hash'), isTrue);
    });

    test('generateSalt returns non-empty secure salt', () {
      final salt1 = PasswordHasher.generateSalt();
      final salt2 = PasswordHasher.generateSalt();
      expect(salt1.isNotEmpty, isTrue);
      expect(salt2.isNotEmpty, isTrue);
      expect(salt1, isNot(equals(salt2)));
    });

    test(
      'hash and verify authenticates matching password and rejects incorrect password',
      () {
        const password = 'SecretPassword123!';
        final salt = PasswordHasher.generateSalt();
        final hash = PasswordHasher.hash(password, salt, rounds: 1000);

        expect(PasswordHasher.verify(password, salt, hash), isTrue);
        expect(PasswordHasher.verify('WrongPassword', salt, hash), isFalse);
        expect(
          PasswordHasher.verify(password, 'different-salt', hash),
          isFalse,
        );
      },
    );
  });

  group('Phase 2 R3: LocalDatabase v7 user_credentials', () {
    late Database rawDb;
    late LocalDatabase localDb;

    setUp(() async {
      rawDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalDatabase.createTestSchema(rawDb);
      localDb = LocalDatabase.forDatabase(rawDb);
    });

    tearDown(() async {
      await rawDb.close();
    });

    test(
      'saves and retrieves user credentials with server origin isolation',
      () async {
        final salt = PasswordHasher.generateSalt();
        final hash = PasswordHasher.hash('pass123', salt);

        await localDb.saveUserCredentials(
          username: 'patient_ahmed',
          serverOrigin: 'https://cloud.epilepsy.app',
          passwordHash: hash,
          salt: salt,
          userProfile: jsonEncode({'id': 'p1', 'name': 'Ahmed'}),
          role: 'patient',
          userId: 'p1',
          updatedAt: DateTime.now().toIso8601String(),
        );

        // Exact match
        final cred = await localDb.getUserCredentials(
          username: 'patient_ahmed',
          serverOrigin: 'https://cloud.epilepsy.app',
        );
        expect(cred, isNotNull);
        expect(cred!['username'], 'patient_ahmed');
        expect(cred['passwordHash'], hash);
        expect(cred['role'], 'patient');

        // Case-insensitive username match
        final caseMatch = await localDb.getUserCredentials(
          username: 'PATIENT_AHMED',
          serverOrigin: 'https://cloud.epilepsy.app',
        );
        expect(caseMatch, isNotNull);

        // Server origin isolation: querying another origin returns null
        final otherOrigin = await localDb.getUserCredentials(
          username: 'patient_ahmed',
          serverOrigin: 'https://local.epilepsy.app',
        );
        expect(otherOrigin, isNull);
      },
    );
  });

  group('Phase 2 R3: AppState Offline Workspace Entry & Credential Caching', () {
    late Database rawDb;
    late LocalDatabase localDb;

    setUp(() async {
      rawDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalDatabase.createTestSchema(rawDb);
      localDb = LocalDatabase.forDatabase(rawDb);
    });

    tearDown(() async {
      await rawDb.close();
    });

    test(
      'online login caches credentials and sets isOfflineWorkspace = false',
      () async {
        final client = MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(
              jsonEncode({
                'access_token': mockJwt(
                  sub: 'user-1',
                  role: 'patient',
                  sid: 'sid-1',
                ),
                'role': 'patient',
                'user': {
                  'id': 'user-1',
                  'username': 'patient1',
                  'name': 'Ahmed Patient',
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.path == '/auth/me') {
            return http.Response(
              jsonEncode({
                'user': {
                  'id': 'user-1',
                  'username': 'patient1',
                  'name': 'Ahmed Patient',
                  'role': 'patient',
                },
                'patients': [
                  {
                    'patientId': 'user-1',
                    'name': 'Ahmed Patient',
                    'diagnosis': 'صرع بؤري',
                    'medications': <String>[],
                    'caregivers': <String>[],
                    'doctors': <String>[],
                    'currentStatus': 'stable',
                    'phone': '',
                    'lastUpdated': DateTime.now().toIso8601String(),
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.path == '/health') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (request.url.path.contains('/notifications/')) {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('{"ok": true}', 200);
        });

        final apiClient = ApiClient(
          client: client,
          baseUrl: 'https://cloud.epilepsy.app',
        );
        final appState = AppState(apiClient: apiClient, database: localDb);

        await appState.signInWithPassword(
          username: 'patient1',
          password: 'Password123',
        );

        expect(appState.auth.currentUser?.uid, 'user-1');
        expect(appState.isOfflineWorkspace, isFalse);
        expect(appState.apiOnline, isTrue);

        // Verify that credentials were saved to SQLCipher user_credentials table
        final stored = await localDb.getUserCredentials(
          username: 'patient1',
          serverOrigin: 'https://cloud.epilepsy.app',
        );
        expect(stored, isNotNull);
        expect(stored!['role'], 'patient');
        expect(stored['userId'], 'user-1');
        expect(
          PasswordHasher.verify(
            'Password123',
            stored['salt'] as String,
            stored['passwordHash'] as String,
          ),
          isTrue,
        );
      },
    );

    test('network failure enters isOfflineWorkspace without wiping tokens', () async {
      // 1. First seed credentials into localDb as if a previous online login occurred
      final salt = PasswordHasher.generateSalt();
      final hash = PasswordHasher.hash('MyOfflinePass', salt);
      final profile = {
        'user': {
          'id': 'offline-pat-1',
          'username': 'offline_user',
          'name': 'Offline Patient',
          'role': 'patient',
        },
        'patients': [
          {
            'patientId': 'offline-pat-1',
            'name': 'Offline Patient',
            'diagnosis': 'صرع بؤري',
            'medications': <String>[],
            'caregivers': <String>[],
            'doctors': <String>[],
            'currentStatus': 'stable',
            'phone': '',
            'lastUpdated': DateTime.now().toIso8601String(),
          },
        ],
      };

      await localDb.saveUserCredentials(
        username: 'offline_user',
        serverOrigin: 'https://cloud.epilepsy.app',
        passwordHash: hash,
        salt: salt,
        userProfile: jsonEncode(profile),
        role: 'patient',
        userId: 'offline-pat-1',
        updatedAt: DateTime.now().toIso8601String(),
      );

      // 2. Setup mock client that simulates complete network offline failure (SocketException)
      final client = MockClient((request) async {
        throw const SocketException('No route to host');
      });

      final apiClient = ApiClient(
        client: client,
        baseUrl: 'https://cloud.epilepsy.app',
      );
      final appState = AppState(apiClient: apiClient, database: localDb);

      // 3. Attempt login with correct offline password
      await appState.signInWithPassword(
        username: 'offline_user',
        password: 'MyOfflinePass',
      );

      expect(appState.auth.currentUser?.uid, 'offline-pat-1');
      expect(appState.auth.currentUser?.name, 'Offline Patient');
      expect(appState.isOfflineWorkspace, isTrue);
      expect(appState.apiOnline, isFalse);
      expect(appState.failure?.kind, FailureKind.offline);

      // 4. Attempt login with incorrect password offline -> raises unauthorized
      expect(
        () => appState.signInWithPassword(
          username: 'offline_user',
          password: 'IncorrectPassword',
        ),
        throwsA(
          isA<Failure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unauthorized,
          ),
        ),
      );
    });
  });
}
