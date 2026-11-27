import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/connectivity_coordinator.dart';
import 'package:epilepsy_monitor/services/connectivity_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late StreamController<List<ConnectivityResult>> net;
  late bool serverUp;
  late ApiClient api;
  late ConnectivityOrchestrator c;
  late int reconnects;

  setUp(() {
    net = StreamController<List<ConnectivityResult>>.broadcast();
    serverUp = true;
    reconnects = 0;
    api = ApiClient(
      baseUrl: 'http://server.test',
      client: MockClient((_) async => serverUp
          ? http.Response('{"status":"ok"}', 200)
          : http.Response('down', 500)),
    );
    c = ConnectivityOrchestrator(
      api: api,
      checkNetwork: () async => [ConnectivityResult.wifi],
      networkChanges: () => net.stream,
      heartbeatEvery: const Duration(hours: 1),
    )..onReconnected = () async => reconnects++;
  });

  tearDown(() async {
    c.dispose();
    api.dispose();
    await net.close();
  });

  test('before the first answer the app is connecting, never local mode',
      () async {
    await c.start();
    expect(c.checked, isFalse);
    expect(c.mode, AppOperatingMode.wakingServer);
    expect(c.mode, isNot(AppOperatingMode.offlineLocal));
  });

  test('server answer → online, and reconnect fires exactly once', () async {
    await c.start();
    expect(await c.probe(), isTrue);
    expect(c.mode, AppOperatingMode.onlineFull);
    expect(reconnects, 1);
    c.report(true);
    expect(reconnects, 1, reason: 'still online: no second flush');
  });

  test('losing the network → local mode; regaining it → online + flush',
      () async {
    await c.start();
    await c.probe();
    final modes = <AppOperatingMode>[];
    final sub = c.modes.listen(modes.add);

    net.add([ConnectivityResult.none]);
    await pumpEventQueue();
    expect(c.mode, AppOperatingMode.offlineLocal);
    expect(c.isOnline, isFalse);

    net.add([ConnectivityResult.mobile]);
    await pumpEventQueue();
    expect(c.mode, AppOperatingMode.onlineFull);
    expect(reconnects, 2, reason: 'initial connect + reconnect');
    expect(modes, containsAllInOrder([
      AppOperatingMode.offlineLocal,
      AppOperatingMode.onlineFull,
    ]));
    await sub.cancel();
  });

  test('network up but server failing → server unreachable, not offline',
      () async {
    serverUp = false;
    await c.start();
    expect(await c.probe(), isFalse);
    expect(c.mode, AppOperatingMode.serverUnreachable);
    expect(c.isOnline, isTrue);
  });

  test('every report goes to the one shared state', () async {
    await c.start();
    c.report(true);
    expect(c.serverReachable, isTrue);
    c.report(false);
    expect(c.serverReachable, isFalse);
    expect(c.mode, AppOperatingMode.serverUnreachable);
  });
}
