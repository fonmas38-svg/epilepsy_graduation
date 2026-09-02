import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Hand-offs to the OS: the dialer, the messaging app, a map.
///
/// Every method returns `false` instead of throwing. That is the whole point of
/// the wrapper: these are used on the emergency paths of §3.5 and §4.2, and an
/// exception surfacing from `url_launcher` on a device with no dialer would turn
/// «call my mother» into a crash at the worst possible moment. Callers show the
/// raw number / coordinates as a fallback when `false` comes back.
abstract final class ExternalActions {
  /// Keep digits, `+`, `*`, `#` — everything a dialer understands. Strips the
  /// spaces, dashes and parentheses people type into a contact form.
  static String normalisePhone(String raw) =>
      raw.replaceAll(RegExp(r'[^0-9+*#]'), '');

  static Future<bool> dial(String rawPhone) async {
    final number = normalisePhone(rawPhone);
    if (number.isEmpty) return false;
    return _open(Uri(scheme: 'tel', path: number));
  }

  static Future<bool> sms(String rawPhone, {String? body}) async {
    final number = normalisePhone(rawPhone);
    if (number.isEmpty) return false;
    return _open(
      Uri(
        scheme: 'sms',
        path: number,
        queryParameters: body == null || body.isEmpty ? null : {'body': body},
      ),
    );
  }

  /// Open walking/driving directions to a coordinate.
  ///
  /// Uses the universal `https://` maps URL rather than the platform-specific
  /// `geo:` / `maps:` schemes: it needs no Android `<queries>` manifest entry,
  /// still opens the installed maps app when there is one, and falls back to the
  /// browser when there is not.
  static Future<bool> directions({
    required double latitude,
    required double longitude,
  }) {
    final query = '$latitude,$longitude';
    return _open(
      Uri.https('www.google.com', '/maps/dir/', {
        'api': '1',
        'destination': query,
      }),
      mode: LaunchMode.externalApplication,
    );
  }

  /// Show a coordinate on a map without routing.
  static Future<bool> showOnMap({
    required double latitude,
    required double longitude,
  }) {
    return _open(
      Uri.https('www.google.com', '/maps/search/', {
        'api': '1',
        'query': '$latitude,$longitude',
      }),
      mode: LaunchMode.externalApplication,
    );
  }

  /// Copy text to the clipboard. The fallback when [dial] fails — the number
  /// stays reachable by hand instead of being lost.
  static Future<bool> copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _open(
    Uri uri, {
    LaunchMode mode = LaunchMode.platformDefault,
  }) async {
    try {
      // `canLaunchUrl` is deliberately not consulted first: on Android 11+ it
      // reports false unless the scheme is declared in `<queries>`, which would
      // make a correctly-installed dialer look unavailable. Attempting the
      // launch and catching is both simpler and more accurate.
      return await launchUrl(uri, mode: mode);
    } catch (_) {
      return false;
    }
  }
}
