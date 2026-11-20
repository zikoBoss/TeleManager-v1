import 'provider_error.dart';

/// Maps a TDLib error (numeric [code] + [message]) onto the generic
/// [ProviderError] taxonomy.
///
/// Evidence base: the spike's on-device runs (Task 03/04) and the
/// `FloodWaitPolicy` / error handling proven there. TDLib messages do
/// not contain credentials; the mapper never adds user input to a
/// message, so no secret can leak through an error (PROJECT_RULES #16).
ProviderError mapTdlibError(int code, String message) {
  // Rate limiting always carries FLOOD_WAIT_<seconds> in TDLib.
  final floodWait = _parseFloodWait(message);
  if (floodWait != null) {
    return ProviderFloodWait(floodWait);
  }

  // Authorization problems: the session is gone or was never valid.
  // NOTE: mapping to "unauthenticated" must never trigger an automatic
  // database wipe (spike rule from Task 04).
  if (code == 401 ||
      message.contains('AUTH_KEY_UNREGISTERED') ||
      message.contains('SESSION_REVOKED')) {
    return const ProviderUnauthenticated(
      'The Telegram session is no longer valid.',
    );
  }

  // A wrong verification code proves only that the server refused the
  // input — never that any code was delivered.
  if (code == 400 && message.contains('PHONE_CODE_INVALID')) {
    return const ProviderInvalidInput('Wrong verification code.');
  }

  // Resend refused by the server (next type is null / timeout active).
  // The exact TDLib string is present in the 1.8.67 binary (Task 04 audit).
  if (message.contains("can't be resend")) {
    return const ProviderInvalidInput(
      'The authentication code cannot be resent yet.',
    );
  }

  if (code == 404) {
    return const ProviderNotFound();
  }

  if (code == 403) {
    return const ProviderPermissionDenied();
  }

  // A bare 429 without a FLOOD_WAIT_ duration: treat as a rate limit
  // with a conservative fallback. TDLib normally includes the exact
  // seconds in the message (handled above).
  if (code == 429) {
    return const ProviderFloodWait(
      Duration(seconds: 60),
      'Rate limited by the provider.',
    );
  }

  if (_looksLikeNetworkError(message)) {
    return ProviderNetwork(message);
  }

  return ProviderUnknown(code.toString(), message);
}

/// Parses `FLOOD_WAIT_<seconds>` into a [Duration].
/// Returns `null` when the message carries no flood-wait duration.
Duration? _parseFloodWait(String message) {
  const prefix = 'FLOOD_WAIT_';
  final index = message.indexOf(prefix);
  if (index < 0) return null;
  final rest = message.substring(index + prefix.length);
  final digits = StringBuffer();
  for (var i = 0; i < rest.length; i++) {
    final ch = rest[i];
    if (ch.codeUnitAt(0) < '0'.codeUnitAt(0) ||
        ch.codeUnitAt(0) > '9'.codeUnitAt(0)) {
      break;
    }
    digits.write(ch);
  }
  final seconds = int.tryParse(digits.toString());
  if (seconds == null) return null;
  return Duration(seconds: seconds);
}

bool _looksLikeNetworkError(String message) {
  final lower = message.toLowerCase();
  return lower.contains('network') || lower.contains('timeout');
}
