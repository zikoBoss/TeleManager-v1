/// Opaque account identifier, minted by the provider.
///
/// TM-Core treats it as an opaque string. It is an identifier, never a
/// secret. For Telegram it is the account's user id rendered as a string.
final class AccountId {
  const AccountId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is AccountId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'AccountId($value)';
}

/// Capabilities reported by the provider for the authenticated account.
///
/// Nullable limits mean "unknown / decided by the server": the provider
/// must never invent a limit, and the server's rejection is authoritative
/// (TELEGRAM_INTEGRATION.md; PROJECT_RULES #2, #3). All limits come from
/// a single source inside the provider — never hard-coded in several
/// places (PROJECT_RULES #2).
final class AccountCapabilities {
  const AccountCapabilities({
    required this.accountId,
    this.maxFileSizeBytes,
    this.supportsResumableUpload = false,
    this.supportsResumableDownload = false,
    this.supportsStreaming = false,
    this.maxConcurrentTransfers,
  });

  final AccountId accountId;

  /// Largest single file the account may store, in bytes.
  /// `null` means unknown: the server decides and may reject.
  final int? maxFileSizeBytes;

  /// Whether an interrupted upload can be resumed.
  final bool supportsResumableUpload;

  /// Whether an interrupted download can be resumed.
  final bool supportsResumableDownload;

  /// Whether streaming is supported. Defaults to `false`: never assume
  /// streaming until tested with the chosen integration
  /// (PROJECT_RULES #18).
  final bool supportsStreaming;

  /// How many transfers may run concurrently, if the provider states
  /// one. `null` means the provider states no limit.
  final int? maxConcurrentTransfers;
}
