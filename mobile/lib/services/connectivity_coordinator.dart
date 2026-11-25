/// One answer to «what can the app do right now?», shared by every screen.
///
/// Before this existed the app had two unrelated signals — `apiOnline` and the
/// API client's cold-start `waking` flag — and a phone with no internet at all
/// showed «waking the cloud server», because a DNS failure looked like a
/// sleeping Render instance. The modes below are resolved in priority order so
/// that the device's own connectivity always wins over anything server-side.
enum AppOperatingMode {
  /// Phone has internet and the backend answered its health check.
  onlineFull,

  /// Phone has internet; the backend is answering 502/503/504 or timing out
  /// while [ApiClient] backs off through a cold start.
  wakingServer,

  /// Phone has internet but the backend is unreachable and no cold-start
  /// retry is running (server down, wrong custom URL, blocked port…).
  serverUnreachable,

  /// Phone has no usable internet (no network interface, or DNS/route
  /// failures). Everything runs on-device; writes wait in the outbox.
  offlineLocal,

  /// Internet and backend are back and the outbox is being flushed.
  reconnectingSyncing,
}

/// Pure resolver so the priority rules can be unit-tested without widgets.
AppOperatingMode resolveOperatingMode({
  required bool deviceHasNetwork,
  required bool noInternetDetected,
  required bool serverReachable,
  required bool waking,
  required bool syncing,
}) {
  if (!deviceHasNetwork || noInternetDetected) {
    return AppOperatingMode.offlineLocal;
  }
  if (syncing && serverReachable) return AppOperatingMode.reconnectingSyncing;
  if (waking) return AppOperatingMode.wakingServer;
  if (serverReachable) return AppOperatingMode.onlineFull;
  return AppOperatingMode.serverUnreachable;
}

/// True when [error] proves the phone itself has no route to the internet
/// (as opposed to the server being slow or asleep).
///
/// Matching is on the message because `SocketException`/`ClientException`
/// wording is the only portable signal across Android, Windows and the
/// `http` package wrappers; OS error codes differ per platform.
bool isNoInternetError(Object error) {
  final text = error.toString().toLowerCase();
  const markers = [
    'failed host lookup', // dart:io DNS failure (all platforms)
    'no address associated with hostname', // Android EAI_NODATA
    'nodename nor servname', // Apple resolver
    'network is unreachable', // ENETUNREACH (101) on Android/Linux
    'no route to host', // EHOSTUNREACH
  ];
  return markers.any(text.contains) || _noInternetErrno.hasMatch(text);
}

/// Android EAI_NODATA (7), ENETUNREACH (101); Windows WSAHOST_NOT_FOUND
/// (11001), WSAENETUNREACH (10051).
final _noInternetErrno = RegExp(r'errno = (7|101|11001|10051)\b');
