import '../../l10n/app_localizations.dart';

/// Human-readable relative time, in the active language.
///
/// Needed because §2.5 requires the offline bar to say «آخر تحديث قبل X» and
/// §3.1 requires the status card to state how old the reading is. A raw
/// timestamp does not answer «is this still true?»; an age does.
///
/// Arabic is not simply pluralised, so this implements the actual rule rather
/// than appending a suffix: 1 → singular, 2 → dual (genitive, after «قبل»),
/// 3–10 → plural, 11+ → singular again.
abstract final class TimeAgo {
  static const _arSeconds = ['ثانية', 'ثانيتين', 'ثوانٍ'];
  static const _arMinutes = ['دقيقة', 'دقيقتين', 'دقائق'];
  static const _arHours = ['ساعة', 'ساعتين', 'ساعات'];
  static const _arDays = ['يوم', 'يومين', 'أيام'];

  static String _arUnit(int n, List<String> forms) {
    if (n == 1) return forms[0];
    if (n == 2) return forms[1];
    if (n >= 3 && n <= 10) return '$n ${forms[2]}';
    return '$n ${forms[0]}';
  }

  static String _enUnit(int n, String unit) =>
      n == 1 ? '1 $unit' : '$n ${unit}s';

  /// A bare duration phrase, e.g. «٥ دقائق» / «5 minutes» — no «ago».
  static String span(Duration d, AppLocalizations l) {
    final secs = d.inSeconds.abs();
    if (l.isArabic) {
      if (secs < 45) return _arUnit(secs < 1 ? 1 : secs, _arSeconds);
      if (secs < 3600) {
        return _arUnit(d.inMinutes.abs().clamp(1, 59), _arMinutes);
      }
      if (secs < 86400) return _arUnit(d.inHours.abs().clamp(1, 23), _arHours);
      return _arUnit(d.inDays.abs().clamp(1, 3650), _arDays);
    }
    if (secs < 45) return _enUnit(secs < 1 ? 1 : secs, 'second');
    if (secs < 3600) return _enUnit(d.inMinutes.abs().clamp(1, 59), 'minute');
    if (secs < 86400) return _enUnit(d.inHours.abs().clamp(1, 23), 'hour');
    return _enUnit(d.inDays.abs().clamp(1, 3650), 'day');
  }

  /// «قبل ٥ دقائق» / «5 minutes ago», with a «just now» shortcut under 10 s.
  static String since(DateTime? at, AppLocalizations l, {DateTime? now}) {
    if (at == null) return l.notSet;
    final delta = (now ?? DateTime.now()).difference(at);
    // Future timestamps mean clock skew. Say «now» rather than «in -3 minutes».
    if (delta.inSeconds.abs() < 10) return l.justNow;
    return l.agoLabel(span(delta, l));
  }

  /// Localized 12-hour wall-clock (`h:mm ص/م` in Arabic, `h:mm AM/PM` in English) (#13).
  static String clock(DateTime at, [AppLocalizations? l]) {
    at = at.toLocal();
    final ar = l?.isArabic ?? true;
    final hour12 = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final minute = at.minute.toString().padLeft(2, '0');
    final period = at.hour < 12 ? (ar ? 'ص' : 'AM') : (ar ? 'م' : 'PM');
    return '$hour12:$minute $period';
  }

  /// Localized 12-hour wall-clock formatting (`h:mm ص/م` in Arabic, `h:mm AM/PM` in English).
  static String clock12h(DateTime at, AppLocalizations l) => clock(at, l);

  /// Formats a stored `"HH:mm"` string into 12-hour `h:mm ص/م` (`AM/PM`).
  static String formatHhmm12h(String hhmm, {bool isArabic = true}) {
    final parts = hhmm.trim().split(':');
    if (parts.length < 2) return hhmm;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return hhmm;
    }
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    final minute = m.toString().padLeft(2, '0');
    final period = h < 12 ? (isArabic ? 'ص' : 'AM') : (isArabic ? 'م' : 'PM');
    return '$hour12:$minute $period';
  }

  /// `yyyy-MM-dd` — used in exports and file names, never localised.
  static String isoDate(DateTime at) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';

  /// `yyyy-MM-dd h:mm ص/م` for list rows that span more than one day.
  static String stamp(DateTime at, [AppLocalizations? l]) =>
      '${isoDate(at.toLocal())} ${clock(at, l)}';
}
