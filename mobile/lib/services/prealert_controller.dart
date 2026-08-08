import 'dart:async';

import '../models/models.dart';

/// Drives the early **pre-alert** lifecycle with a 30-second false-alarm cancel
/// window — the safety valve for seizure *prediction*.
///
/// When a forecast crosses the pre-alert threshold, [start] surfaces the
/// pre-alert and begins a 30-second countdown. If the patient does not [cancel]
/// in time, [onEscalate] fires (routing to the normal alert/cloud path so the
/// caregiver and doctor are notified). Cancelling within the window logs a
/// false alarm via [onCancel] and escalates nothing.
///
/// Additive and self-contained: it owns only timers and the active pre-alert,
/// and reports out through callbacks so it plugs into `AppState` the same way
/// `MonitoringService` already does.
class PreAlertController {
  PreAlertController({this.cancelWindow = const Duration(seconds: 30)});

  /// How long the patient has to cancel before escalation.
  final Duration cancelWindow;

  AlertItem? active;
  int secondsLeft = 0;
  Timer? _ticker;

  /// Notifies the UI on every state change (start / tick / stop).
  void Function()? onUpdate;

  /// Called when the cancel window elapses without a cancel.
  Future<void> Function(AlertItem preAlert)? onEscalate;

  /// Called when the patient cancels within the window (false alarm).
  Future<void> Function(AlertItem preAlert)? onCancel;

  bool get isActive => active != null;

  /// Begin the countdown for [preAlert]. Ignored if one is already active so a
  /// stream of preictal ticks doesn't keep resetting the 30-second window.
  void start(AlertItem preAlert) {
    if (active != null) return;
    active = preAlert;
    secondsLeft = cancelWindow.inSeconds;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    onUpdate?.call();
  }

  void _tick() {
    secondsLeft -= 1;
    if (secondsLeft <= 0) {
      // ignore: discarded_futures
      _escalate();
    } else {
      onUpdate?.call();
    }
  }

  Future<void> _escalate() async {
    final a = active;
    _stop();
    if (a != null) await onEscalate?.call(a);
    onUpdate?.call();
  }

  /// Patient dismissed the pre-alert in time → false alarm, no escalation.
  Future<void> cancel() async {
    final a = active;
    _stop();
    if (a != null) await onCancel?.call(a);
    onUpdate?.call();
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
    active = null;
    secondsLeft = 0;
  }

  void dispose() {
    _ticker?.cancel();
    _ticker = null;
  }
}
