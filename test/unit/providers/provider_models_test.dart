import 'package:flutter_test/flutter_test.dart';
import 'package:telemanager/providers/account_capabilities.dart';
import 'package:telemanager/providers/auth_state.dart';
import 'package:telemanager/providers/capability_status.dart';
import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/storage_object.dart';
import 'package:telemanager/providers/transfer_models.dart';

void main() {
  group('ProviderError', () {
    test('toString carries code and message', () {
      expect(
        const ProviderUnauthenticated().toString(),
        contains('unauthenticated'),
      );
    });

    test('flood wait carries its duration', () {
      const error = ProviderFloodWait(Duration(seconds: 42));
      expect(error.retryAfter, const Duration(seconds: 42));
      expect(error.code, 'flood_wait');
    });
  });

  group('AuthState', () {
    test('authenticated carries the account', () {
      const state = AuthAuthenticated(AccountInfo(accountId: AccountId('123')));
      expect(state.account.accountId.value, '123');
    });

    test('awaiting input carries the step', () {
      const state = AuthAwaitingInput(_TestStep());
      expect(state.step.kind, 'test_step');
    });

    test('failed carries the error', () {
      const state = AuthFailed(ProviderUnauthenticated());
      expect(state.error, isA<ProviderUnauthenticated>());
    });
  });

  group('AccountCapabilities', () {
    test('unknown limits are null by default, statuses are unknown', () {
      const caps = AccountCapabilities(accountId: AccountId('1'));
      expect(caps.maxFileSizeBytes, isNull);
      expect(caps.supportsStreaming, CapabilityStatus.unknown);
      expect(caps.supportsResumableUpload, CapabilityStatus.unknown);
      expect(caps.supportsResumableDownload, CapabilityStatus.unknown);
      expect(caps.maxConcurrentTransfers, isNull);
    });

    test('CapabilityStatus has four distinct values', () {
      expect(CapabilityStatus.values, hasLength(4));
      expect(CapabilityStatus.values.toSet(), {
        CapabilityStatus.supported,
        CapabilityStatus.unsupported,
        CapabilityStatus.unknown,
        CapabilityStatus.conditional,
      });
    });
  });

  group('identity separation (PROJECT_RULES #6)', () {
    test('FileId and StorageObjectId are distinct value types', () {
      const fileId = FileId('internal-uuid');
      const objectId = StorageObjectId('provider-ref');
      expect(fileId.value, isNot('provider-ref'));
      expect(objectId.value, isNot('internal-uuid'));
      expect(fileId, const FileId('internal-uuid'));
      expect(objectId, const StorageObjectId('provider-ref'));
    });

    test('a StorageObject links a file to a provider reference', () {
      const object = StorageObject(
        id: StorageObjectId('obj-1'),
        fileId: FileId('file-1'),
        provider: 'telegram',
        accountId: AccountId('acc-1'),
        remoteUniqueId: 'remote-1',
      );
      expect(object.fileId.value, 'file-1');
      expect(object.id.value, 'obj-1');
      expect(object.provider, 'telegram');
      expect(object.remoteStatus, RemoteStatus.unknown);
    });
  });

  group('transfer models', () {
    test('progress carries transferred and optional total', () {
      const progress = TransferProgress(
        operationId: OperationId('op-1'),
        transferredBytes: 100,
        totalBytes: 1000,
      );
      expect(progress.transferredBytes, 100);
      expect(progress.totalBytes, 1000);
    });

    test('upload request keeps the caller-computed checksum', () {
      const request = UploadRequest(
        fileId: FileId('f'),
        localPath: '/tmp/f',
        fileName: 'f',
        fileSizeBytes: 10,
        checksumSha256: 'abc',
      );
      expect(request.checksumSha256, 'abc');
      expect(request.fileSizeBytes, 10);
    });

    test('download result records whether the checksum verified', () {
      const result = DownloadResult(
        fileId: FileId('f'),
        localPath: '/tmp/f',
        sizeBytes: 10,
        checksumVerified: false,
      );
      expect(result.checksumVerified, isFalse);
    });
  });
}

final class _TestStep implements AuthStep {
  const _TestStep();

  @override
  String get kind => 'test_step';
}
