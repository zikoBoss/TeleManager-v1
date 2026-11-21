/// Sanitizes Harness log lines and report text.
///
/// Defense-in-depth (PROJECT_RULES #16): the controller never puts
/// secrets into the log in the first place. This function is the safety
/// net — it redacts anything that looks like a secret if it ever
/// reaches a log line, so a bug cannot leak one.
///
/// Redacted patterns:
/// - Telegram login links (`tg://...`) — replaced, never shown.
/// - A 32-byte key in Base64 (44 characters) — replaced.
/// - An international phone number (`+` followed by 7+ digits).
///
/// The function is pure and unit-tested. It never throws.
String sanitizeLogLine(String line) {
  var result = line;
  // Telegram login link (the QR link). Never shown or logged.
  result = result.replaceAll(RegExp(r'tg://\S+'), '[auth-link-redacted]');
  // A 32-byte key in Base64 is exactly 44 characters ending in '='.
  result = result.replaceAll(RegExp(r'[A-Za-z0-9+/]{43}='), '[key-redacted]');
  // An international phone number.
  result = result.replaceAll(RegExp(r'\+\d{7,}'), '[phone-redacted]');
  return result;
}

/// Returns `true` when [line] contains no redacted secret pattern
/// (i.e. it is safe to include in a report). Used by tests and by the
/// log's own assertion.
bool isLogLineClean(String line) {
  return sanitizeLogLine(line) == line;
}
