/// Moved to `core/ui/risk_indicator.dart`.
///
/// The old `StatusBadge` conveyed the risk level through **colour alone**, which
/// `docs/frontend-plan-ar.md` §2.4 forbids outright (and §7 repeats for
/// accessibility): a colour-blind reader, a greyscale screenshot or a
/// screen-reader user got no information at all. Its replacement, [RiskBadge],
/// always pairs colour with an icon *and* a word.
///
/// This file stays as a re-export so any import of the old path keeps resolving
/// to exactly one implementation instead of two drifting copies.
library;

export '../core/ui/risk_indicator.dart' show RiskBadge, RiskGauge, RiskStrip;
