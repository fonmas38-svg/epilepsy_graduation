import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import 'edge_onnx_runner.dart';

/// [EdgeInferenceBackend] on Microsoft ONNX Runtime (`onnxruntime` plugin,
/// native 1.15.1 on Android arm32/arm64 and Windows x64).
///
/// Inference runs through `runAsync`, which executes in the plugin's own
/// isolate so a window never blocks the UI thread.
class OrtEdgeBackend implements EdgeInferenceBackend {
  OrtSession? _session;
  String _inputName = 'eeg_stream';
  static bool _envReady = false;

  @override
  String get name => 'onnxruntime';

  @override
  Future<void> load(Uint8List modelBytes) async {
    if (!_envReady) {
      OrtEnv.instance.init();
      _envReady = true;
    }
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(1)
      ..setInterOpNumThreads(1);
    try {
      final session = OrtSession.fromBuffer(modelBytes, options);
      if (session.inputNames.isNotEmpty) _inputName = session.inputNames.first;
      _session = session;
    } finally {
      options.release();
    }
  }

  @override
  Future<List<double>> run(Float32List input) async {
    final session = _session;
    if (session == null) throw StateError('ONNX session not loaded');
    final tensor = OrtValueTensor.createTensorWithDataList(
      [
        [input],
      ],
      [1, 1, input.length],
    );
    final runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = await session.runAsync(runOptions, {_inputName: tensor});
      final value = outputs?.first?.value;
      // Output `risk_score`: shape [1, 2] logits.
      if (value is List && value.isNotEmpty && value.first is List) {
        return [for (final v in value.first as List) (v as num).toDouble()];
      }
      throw StateError('Unexpected ONNX output: $value');
    } finally {
      tensor.release();
      runOptions.release();
      for (final o in outputs ?? const <OrtValue?>[]) {
        o?.release();
      }
    }
  }

  @override
  void close() {
    _session?.release();
    _session = null;
  }
}
