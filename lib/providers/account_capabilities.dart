import 'capability_status.dart';

/// Opaque account identifier, minted by the provider.
///
/// TM-Core treats it as an opaque string. It is an identifier, never a
/// secret. For Telegram it is the account's user id rendered as a string.
final class AccountId {
  const AccountId(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is AccountId && other.value == value;

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
///
/// Capability flags are [CapabilityStatus], not `bool`: a plain `bool`
/// cannot tell "unsupported" from "unknown" from "supported by the
/// library but not implemented in TeleManager yet". See
/// [CapabilityStatus] for the exact meaning of each value.
final class AccountCapabilities {
  const AccountCapabilities({
    required this.accountId,
    this.maxFileSizeBytes,
    this.supportsResumableUpload = CapabilityStatus.unknown,
    this.supportsResumableDownload = CapabilityStatus.unknown,
    this.supportsStreaming = CapabilityStatus.unknown,
    this.maxConcurrentTransfers,
  });

  final AccountId accountId;

  /// Largest single file the account may store, in bytes.
  /// `null` means unknown: the server decides and may reject.
  final int? maxFileSizeBytes;

  /// Whether an interrupted upload can be resumed.
  ///
  /// `conditional` means the library supports it but TeleManager does
  /// not implement it yet (the condition is stated by the provider);
  /// it never means "implemented now".
  final CapabilityStatus supportsResumableUpload;

  /// Whether an interrupted download can be resumed.
  ///
  /// `conditional` means the library supports it but TeleManager does
  /// not implement it yet (the condition is stated by the provider);
  /// it never means "implemented now".
  final CapabilityStatus supportsResumableDownload;

  /// Whether streaming is supported. Defaults to [CapabilityStatus.unknown]:
  /// never assume streaming until tested with the chosen integration
  /// (PROJECT_RULES #18).
  final CapabilityStatus supportsStreaming;

  /// How many transfers may run concurrently, if the provider states
  /// one. `null` means the provider states no limit.
  final int? maxConcurrentTransfers;
}
