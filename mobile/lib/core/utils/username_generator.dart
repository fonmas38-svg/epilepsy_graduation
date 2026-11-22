/// Deterministic Arabic-to-Latin username generator for clinical accounts (#6).
class UsernameGenerator {
  UsernameGenerator._();

  static const Map<String, String> _arabicToLatin = {
    'ا': 'a',
    'أ': 'a',
    'إ': 'i',
    'آ': 'a',
    'ء': 'a',
    'ب': 'b',
    'ت': 't',
    'ة': 'h',
    'ث': 'th',
    'ج': 'j',
    'ح': 'h',
    'خ': 'kh',
    'د': 'd',
    'ذ': 'dh',
    'ر': 'r',
    'ز': 'z',
    'س': 's',
    'ش': 'sh',
    'ص': 's',
    'ض': 'd',
    'ط': 't',
    'ظ': 'z',
    'ع': 'a',
    'غ': 'gh',
    'ف': 'f',
    'ق': 'q',
    'ك': 'k',
    'ل': 'l',
    'م': 'm',
    'ن': 'n',
    'ه': 'h',
    'و': 'w',
    'ؤ': 'w',
    'ي': 'y',
    'ى': 'a',
    'ئ': 'y',
    '٠': '0',
    '١': '1',
    '٢': '2',
    '٣': '3',
    '٤': '4',
    '٥': '5',
    '٦': '6',
    '٧': '7',
    '٨': '8',
    '٩': '9',
  };

  static final RegExp _diacritics = RegExp(r'[\u064B-\u065F\u0670\u0640]');
  static final RegExp _leadingHonorific = RegExp(
    r'^(?:الدكتورة|الدكتور|دكتورة|دكتور|د\.|د/|dr\.?)\s*',
    caseSensitive: false,
  );

  /// Transliterates an Arabic or mixed-script name into a lowercase Latin slug.
  static String transliterate(String rawName) {
    final cleaned = rawName
        .trim()
        .replaceAll(_diacritics, '')
        .replaceFirst(_leadingHonorific, '')
        .trim()
        .toLowerCase();
    if (cleaned.isEmpty) return '';

    final buffer = StringBuffer();
    for (final rune in cleaned.runes) {
      final ch = String.fromCharCode(rune);
      final mapped = _arabicToLatin[ch];
      if (mapped != null) {
        buffer.write(mapped);
      } else if (RegExp(r'[a-z0-9]').hasMatch(ch)) {
        buffer.write(ch);
      } else if (ch == ' ' || ch == '_' || ch == '-' || ch == '.') {
        buffer.write('_');
      }
    }

    return buffer
        .toString()
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  /// Generates a clean editable username slug with an optional role prefix and suffix.
  static String generate(
    String fullName, {
    String prefix = '',
    String? suffix,
  }) {
    final baseSlug = transliterate(fullName);
    if (baseSlug.isEmpty) return '';

    final parts = baseSlug.split('_').where((p) => p.isNotEmpty).toList();
    final compact = parts.length <= 2
        ? parts.join('_')
        : '${parts.first}_${parts.last}';

    final cleanPrefix = prefix
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final cleanSuffix = (suffix ?? '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');

    final segments = <String>[
      if (cleanPrefix.isNotEmpty) cleanPrefix,
      compact,
      if (cleanSuffix.isNotEmpty) cleanSuffix,
    ];
    final combined = segments.join('_');
    if (combined.length > 32) {
      return combined.substring(0, 32).replaceAll(RegExp(r'_+$'), '');
    }
    return combined;
  }
}
