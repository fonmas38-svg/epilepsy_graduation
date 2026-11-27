import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'connectivity_coordinator.dart';

/// The ONE source of truth for «can the app reach the cloud right now?».
///
/// It combines three signals that used to be read separately all over the
/// app:
/// * the phone's network interface (`connectivity_plus`),
/// * what the backend actually answered — every health probe and every
///   request outcome reported through [report], plus the API client's
///   «no internet» (DNS/route failure) and «waking» (cold start) notifiers,
/// * a heartbeat that re-checks the server while needed, so a server that
///   comes back is noticed without waiting for a network change.
///
/// Everything else (banners, sync, emergency SMS, location, the monitoring
/// engine) reads [mode] / [isOnline] or listens to [modes]; nothing keeps its
/// own copy. When the cloud becomes reachable again [onReconnected] runs once
/// (it flushes every pending queue).
class ConnectivityOrchestrator extends ChangeNotifier {
  ConnectivityOrchestrator({
    required this.api,
    Future<List<ConnectivityResult>> Function()? checkNetwork,
    Stream<List<ConnectivityResult>> Function()? networkChanges,
    this.heartbeatEvery = const Duration(seconds: 20),
  }) : _checkNetwork =
           checkNetwork ?? (() => Connectivity().checkConnectivity()),
       _networkChanges =
           networkChanges ?? (() => Connectivity().onConnectivityChanged) {
    try {
      api.wakingNotifier.addListener(_onApiSignal);
      api.noInternetNotifier.addListener(_onApiSignal);
      api.deviceOffline = () => !_deviceHasNetwork;
    } catch (_) {}
  }

  final ApiClient api;
  final Future<List<ConnectivityResult>> Function() _checkNetwork;
  final Stream<List<ConnectivityResult>> Function() _networkChanges;
  final Duration heartbeatEvery;

  /// Runs once each time the cloud goes from unreachable to reachable.
  Future<void> Function()? onReconnected;

  /// Whether the heartbeat should probe right now (e.g. only while signed
  /// in, and not while a sync is already probing).
  bool Function()? shouldProbe;

  /// True while pending data is being sent (shown as «syncing»).
  bool Function()? isSyncing;

  bool _deviceHasNetwork = true;
  bool _serverReachable = false;
  bool _checked = false;
  bool _disposed = false;
  AppOperatingMode? _lastMode;
  Timer? _heartbeat;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  final _modes = StreamController<AppOperatingMode>.broadcast();

  bool get deviceHasNetwork => _deviceHasNetwork;
  bool get serverReachable => _serverReachable;

  /// False until the first answer about the server arrived. Until then the
  /// app is «connecting», never «local mode» (that would be a false alarm
  /// for every cold start).
  bool get checked => _checked;

  /// Every change of [mode], for services that react to transitions.
  Stream<AppOperatingMode> get modes => _modes.stream;

  AppOperatingMode get mode {
    bool waking = false, noInternet = false;
    try {
      waking = api.isWakingServer;
      noInternet = api.noInternetDetected;
    } catch (_) {}
    final resolved = resolveOperatingMode(
      deviceHasNetwork: _deviceHasNetwork,
      noInternetDetected: noInternet,
      serverReachable: _serverReachable,
      waking: waking,
      syncing: isSyncing?.call() ?? false,
    );
    // Still establishing the first connection: say «connecting».
    if (!_checked && resolved == AppOperatingMode.serverUnreachable) {
      return AppOperatingMode.wakingServer;
    }
    return resolved;
  }

  /// Cheap «is there a route to the internet?» (no platform call): the
  /// network interface is up and no DNS/route failure was seen.
  bool get isOnline {
    var noInternet = false;
    try {
      noInternet = api.noInternetDetected;
    } catch (_) {}
    return _deviceHasNetwork && !noInternet;
  }

  /// Record what the server just answered (true = it responded). Every place
  /// that learns the server's state reports it here, so there is one answer.
  void report(bool reachable) {
    _checked = true;
    final was = _serverReachable;
    _serverReachable = reachable;
    if (reachable && !was) _fireReconnected();
    _changed();
  }

  /// Probe the active server now and [report] the result.
  Future<bool> probe({Duration timeout = const Duration(seconds: 8)}) async {
    if (!_deviceHasNetwork) {
      report(false);
      return false;
    }
    final ok = await api.health(null, timeout, true);
    if (_disposed) return ok;
    report(ok);
    return ok;
  }

  /// Read the current network state, then follow changes and start the
  /// heartbeat. Safe to call again (restarts cleanly).
  Future<void> start() async {
    try {
      final initial = await _checkNetwork();
      _deviceHasNetwork = initial.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      // Unknown platform state: assume a network and let requests decide.
    }
    await _sub?.cancel();
    try {
      _sub = _networkChanges().listen(_onNetwork);
    } catch (_) {}
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatEvery, (_) => _beat());
    _changed();
  }

  Future<void> _onNetwork(List<ConnectivityResult> results) async {
    final has = results.any((r) => r != ConnectivityResult.none);
    _deviceHasNetwork = has;
    if (!has) {
      _serverReachable = false;
      _checked = true;
      _changed();
      return;
    }
    // A new network: forget the previous DNS failure and probe again.
    try {
      api.noInternetNotifier.value = false;
    } catch (_) {}
    _changed();
    await probe(timeout: const Duration(seconds: 10));
  }

  Future<void> _beat() async {
    if (_disposed || !_deviceHasNetwork) return;
    if (!(shouldProbe?.call() ?? true)) return;
    await probe();
  }

  void _fireReconnected() {
    final cb = onReconnected;
    if (cb == null) return;
    unawaited(cb().catchError((Object _) {}));
  }

  void _onApiSignal() => _changed();

  void _changed() {
    if (_disposed) return;
    final m = mode;
    if (m != _lastMode) {
      _lastMode = m;
      if (!_modes.isClosed) _modes.add(m);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    unawaited(_sub?.cancel());
    try {
      api.wakingNotifier.removeListener(_onApiSignal);
      api.noInternetNotifier.removeListener(_onApiSignal);
      api.deviceOffline = null;
    } catch (_) {}
    unawaited(_modes.close());
    super.dispose();
  }
}
