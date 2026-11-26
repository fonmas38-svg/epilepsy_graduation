import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/services/edge_onnx_runner.dart';
import 'package:epilepsy_monitor/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'offline_sync_policy_test.dart' show Store, Cloud, Session, reading;

class FakeBackend implements EdgeInferenceBackend {
  FakeBackend(this.logits);
  List<double> logits;
  Float32List? lastInput;
  int loads = 0;
  @override
  String get name => 'fake';
  @override
  Future<void> load(Uint8List modelBytes) async => loads++;
  @override
  Future<List<double>> run(Float32List input) async {
    lastInput = input;
    return logits;
  }

  @override
  void close() {}
}

Future<ByteData> Function(String) assets({Map<String, Object?>? meta}) =>
    (key) async {
      if (key.endsWith('.json')) {
        final bytes = utf8.encode(
          jsonEncode(
            meta ??
                {
                  'input_len': 262,
                  'fs': 256,
                  'decision_threshold': 0.5,
                  'watch_threshold': 0.35,
                },
          ),
        );
        return ByteData.sublistView(Uint8List.fromList(bytes));
      }
      return ByteData(16);
    };

List<double> eeg() => [
  for (var i = 0; i < 262; i++) 20 * math.sin(i * 2 * math.pi * 6 / 256),
];

class _Sync extends SyncService {
  _Sync(Store s, Cloud c, Session a, EdgeOnnxRunner runner)
    : super(db: s, api: c, auth: a, edgeRunner: runner);
  @override
  Future<bool> get isOnline async => false;
}

class _DemoSession extends Session {
  @override
  bool get isDemoSession => true;
}

void main() {
  test('high ictal probability → highRisk, labelled detection-only', () async {
    final backend = FakeBackend([-2, 2]); // softmax ≈ 0.982
    final runner = EdgeOnnxRunner(
      backendFactory: () => backend,
      loadAsset: assets(),
    );
    final r = (await runner.detect(eeg()))!;
    expect(r.label, RiskLabel.highRisk);
    expect(r.features['engine'], 'edge_onnx');
    expect(r.features['task'], 'detection');
    expect(r.features['predicted'], isFalse);
    expect(r.features['lead_time_min'], isNull);
    expect(r.features['ictal_prob'], closeTo(0.982, 1e-3));
    expect(backend.lastInput!.length, 262);
    // Input is z-scored, as in training.
    final mean = backend.lastInput!.reduce((a, b) => a + b) / 262;
    expect(mean.abs(), lessThan(1e-4));
  });

  test('thresholds from meta map to watch / stable', () async {
    final backend = FakeBackend([0, -0.2]); // p ≈ 0.45 → watch
    final runner = EdgeOnnxRunner(
      backendFactory: () => backend,
      loadAsset: assets(),
    );
    expect((await runner.detect(eeg()))!.label, RiskLabel.watch);
    backend.logits = [2, -2];
    expect((await runner.detect(eeg()))!.label, RiskLabel.stable);
    expect(backend.loads, 1, reason: 'model is loaded once');
  });

  test('unusable window is reported as not assessed, not as safe', () async {
    final runner = EdgeOnnxRunner(
      backendFactory: () => FakeBackend([0, 0]),
      loadAsset: assets(),
    );
    final r = (await runner.detect(List<double>.filled(262, 1)))!;
    expect(r.features['assessment_valid'], isFalse);
    expect(r.confidence, 0);
  });

  test('no runtime or mismatched model contract → unavailable', () async {
    final none = EdgeOnnxRunner(loadAsset: assets());
    expect(await none.detect(eeg()), isNull);
    expect(none.unavailableReason, 'onnx_runtime_not_installed');

    final mismatch = EdgeOnnxRunner(
      backendFactory: () => FakeBackend([0, 0]),
      loadAsset: assets(meta: {'input_len': 512, 'fs': 256}),
    );
    expect(await mismatch.detect(eeg()), isNull);
    expect(mismatch.unavailableReason, 'model_contract_mismatch');
  });

  group('offline routing in SyncService', () {
    test('real patient uses the ONNX model when available', () async {
      final runner = EdgeOnnxRunner(
        backendFactory: () => FakeBackend([-2, 2]),
        loadAsset: assets(),
      );
      final sync = _Sync(Store(), Cloud(), Session(), runner);
      final a = await sync.analyzeAndStore(reading());
      expect(a.features['engine'], 'edge_onnx');
      expect(a.features['model_executed'], isTrue);
    });

    test('real patient without runtime never gets demo heuristics', () async {
      final sync = _Sync(
        Store(),
        Cloud(),
        Session(),
        EdgeOnnxRunner(loadAsset: assets()),
      );
      final a = await sync.analyzeAndStore(reading());
      expect(a.features['engine'], 'unavailable');
      expect(a.features['capability_reason'], 'onnx_runtime_not_installed');
    });

    test('demo account without runtime falls back to the heuristic', () async {
      final sync = _Sync(
        Store(),
        Cloud(),
        _DemoSession(),
        EdgeOnnxRunner(loadAsset: assets()),
      );
      final a = await sync.analyzeAndStore(reading());
      expect(a.features['engine'], 'edge_heuristic');
    });
  });
}
