// ignore: depend_on_referenced_packages
import 'dart:convert';
import 'dart:math';
import 'dart:isolate';
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart';

class PasswordHasher {
  static String generateSalt([int length = 16]) {
    final rnd = Random.secure();
    final bytes = List<int>.generate(length, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes);
  }

  static const iterations = 600000;

  static String hash(String password, String salt, {int rounds = iterations}) {
    if (rounds < 1 || rounds > 2000000) {
      throw ArgumentError.value(rounds, 'rounds');
    }
    final hmac = Hmac(sha256, utf8.encode(password));
    var block = hmac.convert([...utf8.encode(salt), 0, 0, 0, 1]).bytes;
    final result = List<int>.from(block);
    for (var round = 1; round < rounds; round++) {
      block = hmac.convert(block).bytes;
      for (var i = 0; i < result.length; i++) {
        result[i] ^= block[i];
      }
    }
    final hex = result.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'pbkdf2-sha256\$$rounds\$$hex';
  }

  static Future<String> hashAsync(String password, String salt) =>
      Isolate.run(() => hash(password, salt));

  static Future<bool> verifyAsync(String password, String salt, String hash) =>
      Isolate.run(() => verify(password, salt, hash));

  static bool needsRehash(String hash) =>
      !hash.startsWith('pbkdf2-sha256\$$iterations\$');

  static bool verify(String password, String salt, String expectedHash) {
    String actual;
    if (expectedHash.startsWith('pbkdf2-sha256\$')) {
      final parts = expectedHash.split('\$');
      if (parts.length != 3) return false;
      final rounds = int.tryParse(parts[1]);
      if (rounds == null || rounds < 1 || rounds > 2000000) return false;
      actual = hash(password, salt, rounds: rounds);
    } else {
      // Verify an existing legacy cache once; callers upgrade it after success.
      actual = sha256.convert(utf8.encode('$salt:$password')).toString();
    }
    if (actual.length != expectedHash.length) return false;
    var result = 0;
    for (var i = 0; i < actual.length; i++) {
      result |= actual.codeUnitAt(i) ^ expectedHash.codeUnitAt(i);
    }
    return result == 0;
  }
}
