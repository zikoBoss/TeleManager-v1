import 'storage_object.dart';
import 'transfer_models.dart';

/// Transfer operations of a storage provider (TM-Cloud).
///
/// Defined in Task 05, implemented in Task 06. Splitting this from
/// [StorageProvider] keeps Task 05 free of unimplemented methods and
/// fake results: a provider implements [StorageProvider] first
/// (lifecycle, authentication, capabilities) and adds this interface
/// when its transfers are real.
///
/// All methods require an initialized, authenticated provider; they
/// throw the matching [ProviderError] otherwise. An operation must
/// never be reported completed before the provider confirms success
/// and the caller persists the remote reference (PROJECT_RULES #8).
/// Cancellation is best-effort: the operation ends as cancelled, or
/// completes if it already finished.
abstract interface class StorageOperations {
  /// Uploads a local file. Reports progress through [onProgress].
  Future<UploadResult> uploadFile(
    UploadRequest request,
    ProgressCallback onProgress,
  );

  /// Downloads a remote object to [DownloadRequest.destinationPath].
  /// Reports progress through [onProgress].
  Future<DownloadResult> downloadFile(
    DownloadRequest request,
    ProgressCallback onProgress,
  );

  /// Deletes the remote object. Must never be called as a side effect
  /// of clearing a local cache (PROJECT_RULES #7).
  Future<void> deleteFile(StorageObjectId id);

  /// Provider-reported metadata for a remote object.
  Future<RemoteFileInfo> getFileInfo(StorageObjectId id);

  /// Requests cancellation of the operation. Best-effort (see above).
  Future<void> cancelOperation(OperationId id);
}
