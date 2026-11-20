/// Generic storage-provider error taxonomy (TM-Cloud).
///
/// No Telegram/TDLib types appear here. A [ProviderError] carries only
/// provider-agnostic codes and sanitized messages: never credentials,
/// session data, or encryption keys (PROJECT_RULES #16).
///
/// The provider maps its own errors onto these variants (see
/// `telegram_errors.dart` for the TDLib mapping). Callers switch on the
/// concrete type; [code] is a stable machine-readable identifier.
sealed class ProviderError implements Exception {
  const ProviderError();

  /// Stable machine-readable code, e.g. `'unauthenticated'`.
  String get code;

  /// Human-readable message. Must never contain secrets.
  String get message;

  @override
  String toString() => 'ProviderError($code): $message';
}

/// A method was called before [StorageProvider.initialize].
final class ProviderNotInitialized extends ProviderError {
  const ProviderNotInitialized([
    this.message = 'Storage provider is not initialized.',
  ]);

  @override
  String get code => 'not_initialized';

  @override
  final String message;
}

/// No authenticated session exists (or it expired / was revoked).
final class ProviderUnauthenticated extends ProviderError {
  const ProviderUnauthenticated([
    this.message = 'No authenticated session. Authenticate first.',
  ]);

  @override
  String get code => 'unauthenticated';

  @override
  final String message;
}

/// Network failure, timeout, or unreachable provider.
final class ProviderNetwork extends ProviderError {
  const ProviderNetwork([this.message = 'Network error.']);

  @override
  String get code => 'network';

  @override
  final String message;
}

/// The account limit was exceeded (size, count, or quota).
/// The server's rejection is authoritative; the provider must not
/// invent limits (TELEGRAM_INTEGRATION.md).
final class ProviderQuotaExceeded extends ProviderError {
  const ProviderQuotaExceeded([this.message = 'Account limit exceeded.']);

  @override
  String get code => 'quota_exceeded';

  @override
  final String message;
}

/// The referenced object no longer exists, or its reference expired.
final class ProviderNotFound extends ProviderError {
  const ProviderNotFound([
    this.message = 'Referenced object not found or reference expired.',
  ]);

  @override
  String get code => 'not_found';

  @override
  final String message;
}

/// The account lacks permission for the requested operation.
final class ProviderPermissionDenied extends ProviderError {
  const ProviderPermissionDenied([
    this.message = 'Permission denied for this operation.',
  ]);

  @override
  String get code => 'permission_denied';

  @override
  final String message;
}

/// The provider rate-limited the request (Telegram `FLOOD_WAIT`).
/// [retryAfter] is the duration the provider requires the caller to
/// wait. The caller must respect it (PROJECT_RULES #3).
final class ProviderFloodWait extends ProviderError {
  const ProviderFloodWait(
    this.retryAfter, [
    this.message = 'Rate limited by the provider.',
  ]);

  @override
  String get code => 'flood_wait';

  @override
  final String message;

  final Duration retryAfter;
}

/// The operation was cancelled (by the user or by the provider).
final class ProviderCancelled extends ProviderError {
  const ProviderCancelled([this.message = 'Operation cancelled.']);

  @override
  String get code => 'cancelled';

  @override
  final String message;
}

/// The input was rejected by the provider (e.g. a wrong verification
/// code). This proves only that the provider refused the input, never
/// that any delivery happened.
final class ProviderInvalidInput extends ProviderError {
  const ProviderInvalidInput([this.message = 'Invalid input.']);

  @override
  String get code => 'invalid_input';

  @override
  final String message;
}

/// An error that maps to no other variant. [providerCode] is the raw
/// provider error code (sanitized, never a secret); [message] is the
/// provider's message with any sensitive content removed by the mapper.
final class ProviderUnknown extends ProviderError {
  const ProviderUnknown(
    this.providerCode, [
    this.message = 'Unknown provider error.',
  ]);

  @override
  String get code => 'unknown';

  @override
  final String message;

  final String providerCode;
}
