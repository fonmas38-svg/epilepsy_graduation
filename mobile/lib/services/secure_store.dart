import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Thin wrapper over platform secure storage (Keychain on iOS, EncryptedShared
/// Preferences / Keystore on Android). Used for two secrets that must never
/// touch plaintext prefs: the backend JWT and the local SQLCipher DB key.
///
/// If the platform keystore is unavailable or throws (e.g. an emulator without
/// keystore support, or a corrupted keychain), it degrades to a process-memory
/// fallback so authentication and DB access never hard-crash. The fallback is
/// not persisted across restarts by design — a temporary, fail-safe path.
class SecureStore {
  SecureStore._();
  static final SecureStore instance = SecureStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final Map<String, String> _memoryFallback = {};

  static const _kDeviceId = 'device_id';

  /// Return the persistent installation/hardware UUID, generating and storing
  /// a fresh UUID v4 on first use. Used to enforce single-device hardware binding.
  Future<String> getOrCreateDeviceId() async {
    final existing = await read(_kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await write(_kDeviceId, id);
    return id;
  }

  Future<String> getDeviceId() => getOrCreateDeviceId();

  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return _memoryFallback[key];
    }
  }

  Future<void> write(String key, String value) async {
    _memoryFallback[key] = value;
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      // keep the in-memory copy; nothing else to do
    }
  }

  Future<void> delete(String key) async {
    _memoryFallback.remove(key);
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }

  /// Return the value at [key], generating and persisting a fresh random
  /// [byteLength]-byte secret (base64url) the first time. Used for the DB key so
  /// it is created once per install and never leaves the device.
  /// Persistent secrets must never silently fall back to volatile memory.
  Future<String?> readSecret(String key) => _storage.read(key: key);

  Future<void> writeSecret(String key, String value) async {
    await _storage.write(key: key, value: value);
    if (await _storage.read(key: key) != value) {
      throw StateError('Secure storage did not persist the secret');
    }
  }

  Future<void> deleteSecret(String key) => _storage.delete(key: key);

  Future<String> readOrCreateSecret(String key, {int byteLength = 32, bool allowCreate = true}) async {
    final existing = await readSecret(key);
    if (existing != null && existing.isNotEmpty) return existing;
    if (!allowCreate) {
      throw StateError('The existing database key is unavailable; recovery is required');
    }
    final rng = Random.secure();
    final bytes = List<int>.generate(byteLength, (_) => rng.nextInt(256));
    final secret = base64Url.encode(bytes);
    await writeSecret(key, secret);
    return secret;
  }
}
