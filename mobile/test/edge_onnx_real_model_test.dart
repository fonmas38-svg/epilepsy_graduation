// ignore_for_file: depend_on_referenced_packages
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:epilepsy_monitor/services/edge_onnx_backend_ort.dart';
import 'package:epilepsy_monitor/services/edge_onnx_runner.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// Windows 10/11 ship an older WinML `onnxruntime.dll` in System32 that the
/// test host would load first. A built app loads the DLL bundled next to its
/// .exe; here we give the plugin's copy priority via SetDllDirectoryW.
void _preferPluginDll() {
  if (!Platform.isWindows) return;
  final dir = Platform.environment['ORT_DLL_DIR'];
  if (dir == null) return;
  final setDir = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Int32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('SetDllDirectoryW');
  final p = dir.toNativeUtf16();
  setDir(p);
  calloc.free(p);
}

/// Runs the shipped `edge_seizure_model.onnx` through the real native ONNX
/// Runtime. Skipped unless the native library can be loaded on this host
/// (on Windows: put the plugin's `windows/onnxruntime.dll` on PATH).
void main() {
  Future<ByteData> fromDisk(String key) async =>
      ByteData.sublistView(Uint8List.fromList(await File(key).readAsBytes()));

  test('real EdgeSeizureNet runs and returns valid probabilities', () async {
    _preferPluginDll();
    final runner = EdgeOnnxRunner(
      backendFactory: OrtEdgeBackend.new,
      loadAsset: fromDisk,
    );
    final loaded = await runner.ensureLoaded();
    if (!loaded) {
      markTestSkipped(
        'ONNX Runtime not loadable here: ${runner.unavailableReason} ${runner.loadError}',
      );
      return;
    }
    final rng = math.Random(7);
    // Low-amplitude background vs. high-amplitude 3 Hz spike-wave pattern.
    final background = [for (var i = 0; i < 262; i++) rng.nextDouble() * 2 - 1];
    final spikeWave = [
      for (var i = 0; i < 262; i++)
        80 * math.sin(2 * math.pi * 3 * i / 256) +
            (i % 85 < 6 ? 250.0 : 0.0) +
            rng.nextDouble(),
    ];
    final a = (await runner.detect(background))!;
    final b = (await runner.detect(spikeWave))!;
    for (final r in [a, b]) {
      expect(r.features['engine'], 'edge_onnx');
      expect(r.features['model_executed'], isTrue);
      final p = r.features['ictal_prob'] as double;
      expect(p, inInclusiveRange(0, 1));
    }
    // ignore: avoid_print
    print(
      'ictal_prob background=${a.features['ictal_prob']} '
      'spike-wave=${b.features['ictal_prob']} '
      'latency=${b.processingMs.toStringAsFixed(1)} ms',
    );
    runner.dispose();
  });
}
