import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/message_model.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/auth_service.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/message_service.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';

AppUser account(String id, [UserRole role = UserRole.patient]) =>
    AppUser(uid: id, name: id, email: id, role: role);
ChatMessage message(
  String id,
  String patient, {
  String channel = 'doctor_patient',
  bool synced = true,
}) => ChatMessage(
  id: id,
  patientId: patient,
  senderId: patient,
  senderName: patient,
  senderRole: UserRole.patient,
  channelType: channel,
  content: 'Message $id',
  createdAt: DateTime.utc(2026, 11, 11),
  synced: synced,
);

class MessageAuth implements AuthService {
  @override
  AppUser? currentUser = account('p1');
  @override
  List<PatientProfile> accessiblePatients() => ['p1', 'p2']
      .map(
        (id) => PatientProfile(
          patientId: id,
          name: id,
          diagnosis: '',
          medications: [],
          caregivers: [],
          doctors: [],
          currentStatus: RiskLabel.watch,
          lastUpdated: DateTime.now(),
        ),
      )
      .toList();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MessageDb implements LocalDatabase {
  final rows = <ChatMessage>[];
  final queries = <String>[];
  final replaced = <String>[];
  Future<List<ChatMessage>> Function(String, String)? read;
  Future<void> Function(ChatMessage)? insert;
  @override
  Future<List<ChatMessage>> messagesForChannel(
    String patient,
    String channel, {
    int limit = 100,
    String? serverOrigin,
  }) async {
    queries.add('$patient/$channel');
    return read != null
        ? read!(patient, channel)
        : rows
              .where(
                (m) =>
                    m.patientId == patient &&
                    m.channelType == channel &&
                    (serverOrigin == null ||
                        serverOrigin.isEmpty ||
                        m.serverOrigin == serverOrigin),
              )
              .toList();
  }

  @override
  Future<void> insertMessage(ChatMessage row) async {
    if (insert != null) await insert!(row);
    rows.add(row);
  }

  @override
  Future<void> replacePendingMessage(String id, ChatMessage row) async {
    replaced.add(id);
    rows.removeWhere((m) => m.id == id);
    rows.add(row);
  }

  @override
  Future<List<ChatMessage>> unsyncedMessages(String senderId) async =>
      rows.where((m) => !m.synced && m.senderId == senderId).toList();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MessageTokens implements TokenProvider {
  @override
  String? subject = 'p1';
  @override
  bool hasSession = false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MessageApi implements ApiClient {
  @override
  final MessageTokens tokens = MessageTokens();
  @override
  String baseUrl = 'https://test.invalid';
  final calls = <String>[];
  Future<Map<String, dynamic>> Function(String, String, Map<String, Object?>)?
  respond;
  @override
  Future<Map<String, dynamic>> sendJson({
    required String method,
    required String path,
    Map<String, Object?> body = const {},
  }) async {
    calls.add('$method $path');
    return respond != null ? respond!(method, path, body) : {'messages': []};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'logout invalidates a local message load, including return to the same account',
    () async {
      final auth = MessageAuth();
      final db = MessageDb();
      final api = MessageApi();
      final delayed = Completer<List<ChatMessage>>();
      db.read = (_, _) => delayed.future;
      final service = MessageService(db: db, api: api, auth: auth);
      final loading = service.loadFor('p1');
      service.clearSession();
      auth.currentUser = account('p1');
      delayed.complete([message('old', 'p1')]);
      await loading;
      expect(service.doctorMessages, isEmpty);
      expect(service.familyMessages, isEmpty);
      expect(service.patientId, isNull);
      expect(service.loading, isFalse);
    },
  );
  test(
    'a late previous-patient result cannot replace the selected conversation',
    () async {
      final auth = MessageAuth()
        ..currentUser = account('doctor', UserRole.doctor);
      final db = MessageDb();
      final delayed = Completer<List<ChatMessage>>();
      db.read = (pid, channel) async => pid == 'p1'
          ? delayed.future
          : [message('new', pid, channel: channel)];
      final service = MessageService(db: db, api: MessageApi(), auth: auth);
      final first = service.loadFor('p1');
      await service.loadFor('p2');
      delayed.complete([message('old', 'p1')]);
      await first;
      expect(service.patientId, 'p2');
      expect(service.doctorMessages.single.patientId, 'p2');
      expect(service.familyMessages.single.patientId, 'p2');
    },
  );
  test(
    'caregiver never reads the private local cache or queues a private message',
    () async {
      final auth = MessageAuth()
        ..currentUser = account('carer', UserRole.caregiver);
      final db = MessageDb()..rows.add(message('private', 'p1'));
      final service = MessageService(db: db, api: MessageApi(), auth: auth);
      await service.loadFor('p1');
      expect(db.queries, ['p1/family_patient']);
      expect(service.doctorMessages, isEmpty);
      await expectLater(
        service.sendMessage(
          patientId: 'p1',
          channelType: 'doctor_patient',
          content: 'No',
        ),
        throwsArgumentError,
      );
      expect(db.rows.length, 1);
    },
  );
  test(
    'an unauthorized patient is rejected before any local read or write',
    () async {
      final db = MessageDb();
      final service = MessageService(
        db: db,
        api: MessageApi(),
        auth: MessageAuth(),
      );
      await service.loadFor('p2');
      await expectLater(
        service.sendMessage(
          patientId: 'p2',
          channelType: 'family_patient',
          content: 'No',
        ),
        throwsArgumentError,
      );
      expect(db.queries, isEmpty);
      expect(db.rows, isEmpty);
    },
  );
  test(
    'logout during local insertion cannot send with the next account credentials',
    () async {
      final auth = MessageAuth();
      final db = MessageDb();
      final api = MessageApi()..tokens.hasSession = true;
      final pause = Completer<void>();
      db.insert = (_) => pause.future;
      final service = MessageService(db: db, api: api, auth: auth);
      final pending = service.sendMessage(
        patientId: 'p1',
        channelType: 'family_patient',
        content: 'Original sender',
      );
      service.clearSession();
      auth.currentUser = account('p2');
      pause.complete();
      await pending;
      expect(api.calls, isEmpty);
      expect(service.familyMessages, isEmpty);
      expect(db.rows.single.senderId, 'p1');
    },
  );
  test(
    'a mismatched server acknowledgment leaves the original message pending',
    () async {
      final db = MessageDb();
      final api = MessageApi()..tokens.hasSession = true;
      api.respond = (_, _, _) async => {
        'message': message('foreign', 'p2', channel: 'family_patient').toMap(),
      };
      final service = MessageService(db: db, api: api, auth: MessageAuth());
      final result = await service.sendMessage(
        patientId: 'p1',
        channelType: 'family_patient',
        content: 'Test',
      );
      expect(result.synced, isFalse);
      expect(db.replaced, isEmpty);
      expect(db.rows.single.patientId, 'p1');
    },
  );
  test(
    'a null location clears the previous share instead of presenting it as current',
    () async {
      final api = MessageApi()..tokens.hasSession = true;
      api.respond = (_, path, _) async =>
          path.endsWith('/location') ? {'location': null} : {'messages': []};
      final service = MessageService(
        db: MessageDb(),
        api: api,
        auth: MessageAuth(),
      );
      await service.loadFor('p1');
      service.lastSharedLocation = {'latitude': 1, 'longitude': 1};
      await service.fetchLatestLocation('p1');
      expect(service.lastSharedLocation, isNull);
    },
  );
}
