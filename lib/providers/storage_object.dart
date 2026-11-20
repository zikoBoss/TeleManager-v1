import 'account_capabilities.dart';

/// Internal TeleManager file identifier. A UUID minted by TM-Core.
///
/// Never a Telegram message id, tdlib file id, or any provider reference
/// (PROJECT_RULES #6). The provider never sees the internals of a
/// [FileId]; it only echoes it back in requests and results.
final class FileId {
  const FileId(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is FileId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FileId($value)';
}

/// Opaque storage-object reference minted by the provider.
///
/// TM-Core treats it as an opaque handle. The provider maps it
/// internally to its own references (for Telegram: chat id, message id,
/// tdlib file id). Those references are never exposed to TM-Core.
final class StorageObjectId {
  const StorageObjectId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is StorageObjectId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'StorageObjectId($value)';
}

/// Availability of a remote object, as reported by the provider.
enum RemoteStatus {
  /// The object is retrievable.
  available,

  /// The object is known but not retrievable right now.
  unavailable,

  /// The reference expired; the object must be re-resolved or re-uploaded.
  expired,

  /// The provider did not report a status.
  unknown,
}

/// A cloud-side object holding (part of) a TeleManager file.
///
/// Follows Master Blueprint §6.4. Provider-specific references
/// (`chat_id`, `message_id`, `tdlib_file_id`) are NOT fields here: they
/// live in the provider's own record type (see
/// `TelegramStorageReferences`). A file may have more than one
/// [StorageObject], and references may change: never rely on a single
/// provider value to retrieve a file (Blueprint §6.4).
final class StorageObject {
  const StorageObject({
    required this.id,
    required this.fileId,
    required this.provider,
    required this.accountId,
    this.remoteUniqueId,
    this.remoteStatus = RemoteStatus.unknown,
  });

  /// Provider-side handle for this object.
  final StorageObjectId id;

  /// The TeleManager file this object stores.
  final FileId fileId;

  /// Provider name, e.g. `'telegram'`.
  final String provider;

  /// The account that owns the object.
  final AccountId accountId;

  /// Provider-unique reference, when the provider supplies one.
  final String? remoteUniqueId;

  /// Availability as last reported by the provider.
  final RemoteStatus remoteStatus;
}
