import 'storage_object.dart';

/// Identifier of a single transfer operation, minted per operation
/// (a UUID). Used to correlate progress reports and to cancel.
/// TM-Transfer persists it for durable operations (roadmap Task 11).
final class OperationId {
  const OperationId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is OperationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'OperationId($value)';
}

/// Progress of one transfer operation. [totalBytes] is `null` when the
/// provider does not know the total yet.
final class TransferProgress {
  const TransferProgress({
    required this.operationId,
    required this.transferredBytes,
    this.totalBytes,
  });

  final OperationId operationId;
  final int transferredBytes;
  final int? totalBytes;
}

/// Progress callback supplied by the caller of an upload/download.
/// Called on the provider's progress updates; must not block.
typedef ProgressCallback = void Function(TransferProgress progress);

/// Request to upload a local file. The checksum is computed by the
/// caller (Master Blueprint §7.3: checksum before upload) and handed
/// to the provider; the provider does not own checksumming.
final class UploadRequest {
  const UploadRequest({
    required this.fileId,
    required this.localPath,
    required this.fileName,
    required this.fileSizeBytes,
    this.checksumSha256,
  });

  /// The TeleManager file being uploaded.
  final FileId fileId;

  /// Absolute local path of the file to upload.
  final String localPath;

  /// File name as it should appear remotely.
  final String fileName;

  /// Size in bytes (must match the file on disk).
  final int fileSizeBytes;

  /// SHA-256 hex of the file, when the caller computed it.
  final String? checksumSha256;
}

/// Request to download a remote object to a local path.
final class DownloadRequest {
  const DownloadRequest({
    required this.storageObjectId,
    required this.destinationPath,
  });

  /// The remote object to download.
  final StorageObjectId storageObjectId;

  /// Absolute local path the downloaded file is written to.
  final String destinationPath;
}

/// Result of a successful upload. The [storageObject] is the durable
/// reference the caller must persist before marking the operation
/// completed (PROJECT_RULES #8).
final class UploadResult {
  const UploadResult({
    required this.storageObject,
    required this.sizeBytes,
    this.checksumSha256,
  });

  /// The created remote object (its id is the retrieval handle).
  final StorageObject storageObject;

  /// Bytes uploaded, as confirmed by the provider.
  final int sizeBytes;

  /// SHA-256 hex of the uploaded content, when confirmed.
  final String? checksumSha256;
}

/// Result of a successful download.
final class DownloadResult {
  const DownloadResult({
    required this.fileId,
    required this.localPath,
    required this.sizeBytes,
    required this.checksumVerified,
  });

  /// The TeleManager file that was downloaded.
  final FileId fileId;

  /// Absolute local path of the downloaded file.
  final String localPath;

  /// Bytes downloaded.
  final int sizeBytes;

  /// Whether the downloaded content's checksum was verified.
  /// `false` when no checksum was available to verify against.
  final bool checksumVerified;
}

/// Provider-reported metadata for a remote object.
final class RemoteFileInfo {
  const RemoteFileInfo({
    required this.id,
    this.sizeBytes,
    this.fileName,
    this.modifiedAt,
    this.remoteStatus = RemoteStatus.unknown,
  });

  final StorageObjectId id;

  /// Size in bytes, when the provider reports it.
  final int? sizeBytes;

  /// Remote file name, when the provider reports it.
  final String? fileName;

  /// Last modification time, when the provider reports it.
  final DateTime? modifiedAt;

  /// Availability as last reported by the provider.
  final RemoteStatus remoteStatus;
}
