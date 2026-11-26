import 'package:epilepsy_monitor/services/background_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neuroshield/background');
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  tearDown(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('off Android every call is a safe no-op', () async {
    answer((_) => true);
    final s = BackgroundService(isAndroid: false);
    expect(s.supported, isFalse);
    expect(await s.startMonitoring(title: 't', text: 'x'), isFalse);
    expect(await s.isIgnoringBatteryOptimizations(), isTrue);
    expect(await s.canUseFullScreenIntent(), isTrue);
    expect(calls, isEmpty);
  });

  test('start/stop pass text and track state', () async {
    answer((_) => true);
    final s = BackgroundService(isAndroid: true);
    expect(await s.startMonitoring(title: 'المراقبة', text: 'نشطة'), isTrue);
    expect(s.serviceRunning, isTrue);
    expect(calls.single.arguments, {'title': 'المراقبة', 'text': 'نشطة'});
    await s.stopMonitoring();
    expect(s.serviceRunning, isFalse);
    expect(calls.last.method, 'stopMonitoringService');
  });

  test('a failed start is not retried until monitoring stops', () async {
    answer((call) => throw PlatformException(code: 'x', message: 'denied'));
    final s = BackgroundService(isAndroid: true);
    expect(await s.startMonitoring(title: 't', text: 'x'), isFalse);
    expect(s.startFailed, isTrue);
    await s.stopMonitoring();
    expect(s.startFailed, isFalse);
  });

  test('missing native side degrades instead of throwing', () async {
    final s = BackgroundService(isAndroid: true);
    expect(await s.isIgnoringBatteryOptimizations(), isTrue);
    expect(await s.requestIgnoreBatteryOptimizations(), isFalse);
  });
}
