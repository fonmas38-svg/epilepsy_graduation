import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'signal_generator.dart';
import 'sim_types.dart';

/// The truth for one emitted window: kept on the phone for accuracy
/// measurement, never sent to a model.
class SimTruth {
  const SimTruth({
    required this.phase,
    required this.type,
    required this.episode,
    required this.progress,
  });

  final SimPhase phase;
  final SimSeizureType? type;

  /// 0 between episodes; otherwise the episode number.
  final int episode;
  final double progress;

  bool get seizure => (type?.isEpileptic ?? false) && phase.isSeizure;
  bool get preIctal =>
      (type?.isEpileptic ?? false) && phase == SimPhase.preIctal;
}

class SimWindow {
  const SimWindow(this.signals, this.truth);
  final SimSignals signals;
  final SimTruth truth;
}

/// One seizure episode: its type, its own style and its timeline.
class SimEpisode {
  SimEpisode({
    required this.number,
    required this.type,
    required this.steps,
    required this.style,
    required this.startedAt,
  });

  final int number;
  final SimSeizureType type;
  final List<(SimPhase, Duration)> steps;
  final EpisodeStyle style;
  final DateTime startedAt;

  Duration get total => steps.fold(Duration.zero, (a, s) => a + s.$2);
}

/// The virtual sensor's clock: calm for [stableDuration], then one complete
/// seizure (pre-ictal → onset → ictal → offset → recovery), then calm again,
/// forever — and demo buttons on top.
///
/// One-seizure lock: [_episode] is the only slot. Nothing starts an episode
/// without going through [_beginEpisode], which first ends any running one,
/// so two seizures can never overlap — not even with repeated button taps.
class SimulationScheduler extends ChangeNotifier {
  SimulationScheduler({
    required this.generator,
    Random? random,
    DateTime Function()? clock,
    this.persist = true,
  }) : _rng = random ?? Random(),
       _clock = clock ?? DateTime.now {
    _stableEndsAt = _clock().add(stableDuration);
  }

  final SimSignalGenerator generator;
  final Random _rng;
  final DateTime Function() _clock;
  final bool persist;

  static const _prefsKey = 'virtual_sensor_state_v1';

  Duration stableDuration = const Duration(minutes: 10);
  bool autoCycle = true;
  int episodesStarted = 0;

  SimEpisode? _episode;
  late DateTime _stableEndsAt;
  EpisodeStyle _calmStyle = EpisodeStyle(Random(1));

  SimEpisode? get episode => _episode;
  bool get inEpisode => _episode != null;

  /// Phase and position right now.
  SimTruth get current => _truthAt(_clock());

  /// Time left in the current calm period or episode phase.
  Duration get remaining {
    final now = _clock();
    final ep = _episode;
    if (ep == null) {
      return autoCycle
          ? _nonNegative(_stableEndsAt.difference(now))
          : Duration.zero;
    }
    var t = ep.startedAt;
    for (final (_, d) in ep.steps) {
      t = t.add(d);
      if (now.isBefore(t)) return t.difference(now);
    }
    return Duration.zero;
  }

  // ------------------------------------------------------------ controls

  /// «ابدأ نوبة الآن»: starts [type] now. If a seizure is running it is ended
  /// first and the chosen one starts from its very beginning.
  void startSeizure(SimSeizureType type) => _beginEpisode(type);

  /// «أعد النوبة من البداية»: the same seizure type from its first phase.
  void restartSeizure() {
    final ep = _episode;
    if (ep != null) _beginEpisode(ep.type);
  }

  /// «أنهِ النوبة»: jump to recovery, then a fresh calm period.
  void endSeizure() {
    final ep = _episode;
    if (ep == null) return;
    final recovery = ep.steps.firstWhere(
      (s) => s.$1 == SimPhase.recovery,
      orElse: () => (SimPhase.recovery, const Duration(seconds: 60)),
    );
    _episode = SimEpisode(
      number: ep.number,
      type: ep.type,
      steps: [recovery],
      style: ep.style,
      startedAt: _clock(),
    );
    _changed();
  }

  void setAutoCycle(bool on) {
    autoCycle = on;
    if (on && _episode == null) _stableEndsAt = _clock().add(stableDuration);
    _changed();
  }

  void setStableDuration(Duration d) {
    stableDuration = d;
    if (_episode == null) _stableEndsAt = _clock().add(d);
    _changed();
  }

  // ------------------------------------------------------------ streaming

  /// The next window: advances the clock-driven state machine first.
  SimWindow nextWindow() {
    _advance();
    final truth = current;
    final style = _episode?.style ?? _calmStyle;
    final signals = generator.next(
      phase: truth.phase,
      type: truth.type ?? SimSeizureType.tonicClonic,
      progress: truth.progress,
      style: style,
    );
    return SimWindow(signals, truth);
  }

  void _advance() {
    final now = _clock();
    final ep = _episode;
    if (ep != null) {
      if (!now.isBefore(ep.startedAt.add(ep.total))) {
        _episode = null;
        _stableEndsAt = now.add(stableDuration);
        _calmStyle = EpisodeStyle(_rng);
        _changed();
      }
      return;
    }
    if (autoCycle && !now.isBefore(_stableEndsAt)) {
      // Automatic seizures vary their type; artefacts are demo-only.
      const auto = [
        SimSeizureType.tonicClonic,
        SimSeizureType.focal,
        SimSeizureType.absence,
        SimSeizureType.nocturnal,
        SimSeizureType.gradual,
      ];
      _beginEpisode(auto[_rng.nextInt(auto.length)]);
    }
  }

  /// The single entry point that starts an episode (the lock).
  void _beginEpisode(SimSeizureType type) {
    _episode = null; // end any running episode first: never two at once
    episodesStarted++;
    _episode = SimEpisode(
      number: episodesStarted,
      type: type,
      steps: _timeline(type),
      style: EpisodeStyle(_rng),
      startedAt: _clock(),
    );
    _changed();
  }

  List<(SimPhase, Duration)> _timeline(SimSeizureType type) {
    Duration s(int lo, int hi) =>
        Duration(seconds: lo + _rng.nextInt(hi - lo + 1));
    final short = type == SimSeizureType.absence;
    return [
      (
        SimPhase.preIctal,
        type == SimSeizureType.gradual ? s(150, 240) : s(60, 150),
      ),
      (SimPhase.onset, s(8, 20)),
      (SimPhase.ictal, short ? s(10, 25) : s(40, 110)),
      (SimPhase.offset, s(10, 25)),
      (SimPhase.recovery, short ? s(30, 60) : s(90, 180)),
    ];
  }

  SimTruth _truthAt(DateTime now) {
    final ep = _episode;
    if (ep == null) {
      final total = stableDuration.inMilliseconds;
      final left = _stableEndsAt.difference(now).inMilliseconds;
      final p = total == 0 ? 0.0 : 1 - (left / total).clamp(0.0, 1.0);
      return SimTruth(
        phase: SimPhase.stable,
        type: null,
        episode: 0,
        progress: p,
      );
    }
    var t = ep.startedAt;
    for (final (phase, d) in ep.steps) {
      final end = t.add(d);
      if (now.isBefore(end)) {
        final p = d.inMilliseconds == 0
            ? 1.0
            : now.difference(t).inMilliseconds / d.inMilliseconds;
        return SimTruth(
          phase: phase,
          type: ep.type,
          episode: ep.number,
          progress: p,
        );
      }
      t = end;
    }
    return SimTruth(
      phase: SimPhase.recovery,
      type: ep.type,
      episode: ep.number,
      progress: 1,
    );
  }

  static Duration _nonNegative(Duration d) => d.isNegative ? Duration.zero : d;

  // ------------------------------------------------------------ persistence

  void _changed() {
    notifyListeners();
    if (persist) _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ep = _episode;
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'stableSeconds': stableDuration.inSeconds,
          'auto': autoCycle,
          'count': episodesStarted,
          'stableEndsAt': _stableEndsAt.toUtc().toIso8601String(),
          if (ep != null)
            'episode': {
              'number': ep.number,
              'type': ep.type.name,
              'startedAt': ep.startedAt.toUtc().toIso8601String(),
              'steps': [
                for (final (ph, d) in ep.steps) [ph.name, d.inMilliseconds],
              ],
            },
        }),
      );
    } catch (_) {}
  }

  /// Resume where the sensor was (an app restart must not reset the cycle).
  Future<void> restore() async {
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      stableDuration = Duration(seconds: (m['stableSeconds'] as num).toInt());
      autoCycle = m['auto'] as bool? ?? true;
      episodesStarted = (m['count'] as num?)?.toInt() ?? 0;
      _stableEndsAt = DateTime.parse(m['stableEndsAt'] as String).toLocal();
      final e = m['episode'] as Map<String, dynamic>?;
      if (e != null) {
        _episode = SimEpisode(
          number: (e['number'] as num).toInt(),
          type: SimSeizureType.values.byName(e['type'] as String),
          startedAt: DateTime.parse(e['startedAt'] as String).toLocal(),
          style: EpisodeStyle(_rng),
          steps: [
            for (final s in e['steps'] as List)
              (
                SimPhase.values.byName(s[0] as String),
                Duration(milliseconds: (s[1] as num).toInt()),
              ),
          ],
        );
      }
      // Long gap: whatever was running has finished; start a calm period.
      final now = _clock();
      final ep = _episode;
      if (ep != null && !now.isBefore(ep.startedAt.add(ep.total))) {
        _episode = null;
        _stableEndsAt = now.add(stableDuration);
      } else if (ep == null && _stableEndsAt.isBefore(now)) {
        _stableEndsAt = now.add(stableDuration);
      }
      notifyListeners();
    } catch (_) {}
  }
}
