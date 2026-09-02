import '../enums.dart';

/// The four risk states the **UI** may display.
///
/// Deliberately a separate type from [RiskLabel] (the backend's detection
/// label). The interface needs a fourth state the backend never sends —
/// `unknown` — for when the model is unreachable, the device is offline, or the
/// newest assessment is stale.
///
/// `docs/frontend-plan-ar.md` §3.1 and §11.1 make this the app's first rule:
/// absence of data must render as «غير معروف», never as «آمن». Keeping the
/// display enum distinct means no `RiskLabel` value can *ever* be mapped to
/// safe-by-accident: [RiskViewX.resolve] is the only constructor, and it
/// demands a freshness proof before it will return [RiskView.safe].
enum RiskView { safe, caution, danger, unknown }

extension RiskViewX on RiskView {
  /// True when this state must be visually loud (danger only).
  bool get isCritical => this == RiskView.danger;

  /// True when we are explicitly admitting we do not know.
  bool get isUnknown => this == RiskView.unknown;

  /// Resolve what to display from a detection label plus a freshness proof.
  ///
  /// * [label] — newest detection label, or null when none exists yet.
  /// * [observedAt] — when that label was produced. Null ⇒ unknown.
  /// * [maxAge] — how old a label may be before it stops meaning anything.
  /// * [dataAvailable] — false when the source (device / backend) is known to
  ///   be down. Forces `unknown` regardless of the cached label, because a
  ///   green badge fed by a dead sensor is a lie.
  static RiskView resolve({
    required RiskLabel? label,
    required DateTime? observedAt,
    Duration maxAge = const Duration(minutes: 5),
    bool dataAvailable = true,
    DateTime? now,
  }) {
    if (!dataAvailable || label == null || observedAt == null) {
      return RiskView.unknown;
    }
    final age = (now ?? DateTime.now()).difference(observedAt);
    // A future-dated reading means clock skew somewhere; treat as untrusted.
    if (age.isNegative || age > maxAge) return RiskView.unknown;
    return switch (label) {
      RiskLabel.stable => RiskView.safe,
      RiskLabel.watch => RiskView.caution,
      RiskLabel.highRisk => RiskView.danger,
    };
  }
}

extension RiskLabelViewX on RiskLabel {
  /// Direct mapping of a label onto the display palette, **without** a freshness
  /// proof.
  ///
  /// Legitimate only for values that are not claims about the patient's state
  /// *right now*: the band of a forecast probability, the severity of an alert
  /// that already happened, a bar in a monthly chart. For anything answering
  /// «كيف حالي الآن؟» use [RiskViewX.resolve] instead — it is the only path that
  /// can return [RiskView.safe], and it demands evidence first (§3.1, §11.1).
  RiskView get bandView => switch (this) {
    RiskLabel.stable => RiskView.safe,
    RiskLabel.watch => RiskView.caution,
    RiskLabel.highRisk => RiskView.danger,
  };
}
