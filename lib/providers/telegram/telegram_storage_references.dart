/// Telegram-specific references for one `StorageObject`.
///
/// Lives in the provider's own record (never in TM-Core). A file is
/// retrieved using all of these together; no single value is trusted
/// alone (Master Blueprint §6.4). Used by the transfer implementation
/// (Task 06); defined here so the identity model is complete in Task 05.
final class TelegramStorageReferences {
  const TelegramStorageReferences({
    this.chatId,
    required this.messageId,
    required this.tdlibFileId,
    this.remoteUniqueId,
  });

  /// Telegram chat id holding the message, when known.
  final int? chatId;

  /// Telegram message id of the message holding the file.
  /// Never a TeleManager internal file id (PROJECT_RULES #6).
  final int messageId;

  /// TDLib file id. May change across sessions; keep it alongside the
  /// message id and re-resolve when needed.
  final int tdlibFileId;

  /// Provider-unique reference, when TDLib supplies one.
  final String? remoteUniqueId;
}
