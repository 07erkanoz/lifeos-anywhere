/// Helpers for working with `LIFE-XXXX-XXXX` activation codes.
class ActivationCodeService {
  ActivationCodeService._();

  /// Expected format: `LIFE-XXXX-XXXX` where X is alphanumeric
  /// (excluding confusing characters 0/O/1/I/L).
  static final _codeRegex = RegExp(
    r'^LIFE-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$',
    caseSensitive: false,
  );

  /// Validates and normalises an activation code.
  ///
  /// Returns the normalised code (uppercased, trimmed, dashes inserted
  /// if missing) or `null` if the input is invalid.
  static String? normalise(String input) {
    var code = input.trim().toUpperCase().replaceAll(RegExp(r'[\s-]+'), '');

    // User may enter just the 12 chars without prefix/dashes.
    if (code.length == 12 && !code.startsWith('LIFE')) {
      code = 'LIFE${code.substring(0, 4)}${code.substring(4, 8)}';
    }

    // Re-insert dashes if stripped.
    if (code.length == 12 && code.startsWith('LIFE')) {
      code = '${code.substring(0, 4)}-${code.substring(4, 8)}-${code.substring(8, 12)}';
    }

    if (_codeRegex.hasMatch(code)) return code;
    return null;
  }

  /// Whether the raw input looks like a valid activation code.
  static bool isValid(String input) => normalise(input) != null;

  /// Formats a raw code string into the display format `LIFE-XXXX-XXXX`.
  static String format(String code) => normalise(code) ?? code;
}
