import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/auth_service.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/sync_service.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';

AppUser user(String uid) =>
    AppUser(uid: uid, name: uid, email: '', role: UserRole.patient);
VitalReading reading() => VitalReading(
  id: 'r1',
  patientId: 'p1',
  timestamp: DateTime.now(),
  eeg: List.generate(262, (i) => (i % 5).toDouble()),
  ecg: [0],
  motion: [0],
  hr: 72,
);

class Session implements AuthService {
  @override
  AppUser? currentUser = user('p1');
  @override
  bool get isDemoSession => false;
  @override
  Future<void> updatePatientStatus(String patientId, RiskLabel status) async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Tokens implements TokenProvider {
  @override
  bool get hasSession => true;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Store implements LocalDatabase {
  final queue = <OutboxItem>[];
  final saved = <RiskAssessment>[];
  final synced = <String>{};
  @override
  Future<void> insertAlert(AlertItem alert, {OutboxItem? delivery}) async {
    if (delivery != null) queue.add(delivery);
  }

  @override
  Future<void> insertAssessment(
    RiskAssessment a, {
    OutboxItem? delivery,
  }) async {
    saved.add(a);
    if (delivery != null) queue.add(delivery);
  }

  @override
  Future<List<OutboxItem>> pendingOutbox({
    int limit = 100,
    String? onlyPath,
    String? excludePath,
    String? ownerId,
  }) async => queue.where((e) => e.body['_ownerId'] == ownerId).toList();
  @override
  Future<void> deleteOutbox(String id) async =>
      queue.removeWhere((e) => e.id == id);
  @override
  Future<void> markSynced(List<String> ids) async => synced.addAll(ids);
  @override
  Future<List<VitalReading>> unsyncedReadings(String patientId) async =>
      synced.contains('r1') ? [] : [reading()];
  @override
  Future<List<RiskAssessment>> assessmentsFor(
    String patientId, {
    int limit = 100,
  }) async => saved;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Cloud implements ApiClient {
  @override
  final TokenProvider tokens = Tokens();
  bool healthy = true;
  int analyses = 0;
  final sent = <Map<String, Object?>>[];
  void Function()? duringAnalysis;
  Completer<void>? pauseSend;
  @override
  Future<bool> health([
    String? overrideUrl,
    Duration timeout = const Duration(seconds: 10),
  ]) async => healthy;
  @override
  Future<AnalyzeResult> analyze(VitalReading r) async {
    analyses++;
    duringAnalysis?.call();
    return AnalyzeResult(
      label: RiskLabel.stable,
      confidence: 0.8,
      features: {'engine': 'cloud-test'},
      processingMs: 1,
    );
  }

  @override
  Future<Map<String, dynamic>> sendJson({
    required String method,
    required String path,
    Map<String, Object?> body = const {},
  }) async {
    sent.add(body);
    await pauseSend?.future;
    return {'ok': true};
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Sync extends SyncService {
  Sync(Store store, Cloud cloud, Session session)
    : super(db: store, api: cloud, auth: session);
  bool online = true;
  @override
  Future<bool> get isOnline async => online;
}

void main() {
  test(
    'cloud success avoids offline inference and synchronizes its assessment',
    () async {
      final store = Store();
      final cloud = Cloud();
      final session = Session();
      final sync = Sync(store, cloud, session);
      final r = reading();
      final result = await sync.analyzeAndStore(r);
      expect(result.features['engine'], 'cloud-test');
      expect(result.timestamp, r.timestamp);
      expect(cloud.analyses, 1);
      expect(cloud.sent.single['assessment'], isNotNull);
      expect(store.queue, isEmpty);
      expect(store.synced, contains('r1'));
    },
  );
  test(
    'real offline session reports unavailable, retains both rows then synchronizes',
    () async {
      final store = Store();
      final cloud = Cloud();
      final session = Session();
      final sync = Sync(store, cloud, session)..online = false;
      final assessment = await sync.analyzeAndStore(reading());
      expect(assessment.confidence, 0);
      expect(assessment.features['assessment_valid'], isFalse);
      expect(assessment.features['model_executed'], isFalse);
      expect(store.queue, hasLength(1));
      expect(cloud.analyses, 0);
      sync.online = true;
      await sync.syncPending('p1');
      expect(store.queue, isEmpty);
      expect((cloud.sent.single['assessment'] as Map)['id'], assessment.id);
    },
  );
  test(
    'account switch during analysis cannot persist results under the new session',
    () async {
      final store = Store();
      final cloud = Cloud();
      final session = Session();
      final sync = Sync(store, cloud, session);
      cloud.duringAnalysis = () => session.currentUser = user('p2');
      await expectLater(sync.analyzeAndStore(reading()), throwsStateError);
      expect(store.saved, isEmpty);
      expect(cloud.sent, isEmpty);
    },
  );
  test('overlapping reconnects send one retained analysis bundle', () async {
    final store = Store();
    final cloud = Cloud();
    final session = Session();
    final sync = Sync(store, cloud, session)..online = false;
    await sync.analyzeAndStore(reading());
    sync.online = true;
    cloud.pauseSend = Completer<void>();
    final first = sync.syncPending('p1');
    await Future<void>.delayed(Duration.zero);
    final second = sync.syncPending('p1');
    cloud.pauseSend!.complete();
    await Future.wait([first, second]);
    expect(cloud.sent, hasLength(1));
  });
  test('saving SOS does not wait for a stalled delivery request', () async {
    final store = Store();
    final cloud = Cloud();
    final session = Session();
    cloud.pauseSend = Completer<void>();
    final sync = Sync(store, cloud, session);
    final saved = await sync
        .sendSos('p1')
        .timeout(const Duration(milliseconds: 100));
    expect(saved.patientId, 'p1');
    expect(store.queue, hasLength(1));
    cloud.pauseSend!.complete();
    await Future<void>.delayed(Duration.zero);
  });
}
