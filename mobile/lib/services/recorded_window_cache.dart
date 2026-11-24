import 'dart:convert';

import 'secure_store.dart';

/// Bounded replay cache of received dataset signals, never a clinical prediction.
class RecordedWindowCache {
  RecordedWindowCache({
    required String scope,
    Future<String?> Function(String)? read,
    Future<void> Function(String, String)? write,
  }) : _key = 'dataset-replay::$scope',
       _read = read ?? SecureStore.instance.read,
       _write = write ?? SecureStore.instance.write;

  final String _key;
  final Future<String?> Function(String) _read;
  final Future<void> Function(String, String) _write;
  List<Map<String, dynamic>>? _windows;
  int _cursor = 0;

  Future<void> _load() async {
    if (_windows != null) return;
    try {
      final raw = await _read(_key);
      _windows = raw == null
          ? []
          : (jsonDecode(raw) as List)
                .whereType<Map>()
                .map((row) => Map<String, dynamic>.from(row))
                .where(valid)
                .take(16)
                .toList();
    } catch (_) {
      _windows = [];
    }
  }

  static bool valid(Map<String, dynamic> window) {
    final eeg = window['eeg'];
    if (eeg is! List || eeg.isEmpty || eeg.length > 512) return false;
    for (final key in ['eeg', 'ecg', 'motion']) {
      final samples = window[key];
      if (samples is! List ||
          samples.length != eeg.length ||
          samples.any((value) => value is! num || !value.isFinite)) {
        return false;
      }
    }
    return window['hr'] is num &&
        (window['hr'] as num).isFinite &&
        DateTime.tryParse(window['timestamp']?.toString() ?? '') != null;
  }

  Future<void> remember(Map<String, dynamic> window) async {
    if (!valid(window)) return;
    await _load();
    // Copy only signal evidence; discard server assessments, identities and tokens.
    final copy = {
      for (final key in ['timestamp', 'eeg', 'ecg', 'motion', 'hr'])
        key: window[key],
    };
    final encoded = jsonEncode(copy);
    if (_windows!.any((row) => jsonEncode(row) == encoded)) return;
    _windows!.add(Map<String, dynamic>.from(jsonDecode(encoded) as Map));
    if (_windows!.length > 16) _windows!.removeAt(0);
    await _write(_key, jsonEncode(_windows));
  }

  Future<Map<String, dynamic>?> next() async {
    await _load();
    if (_windows!.isEmpty) return null;
    return Map<String, dynamic>.from(_windows![_cursor++ % _windows!.length]);
  }
}
