import 'package:flutter_test/flutter_test.dart';
import 'package:telemanager/providers/auth_state.dart';
import 'package:telemanager/providers/capability_status.dart';
import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/storage_provider.dart';
import 'package:telemanager/providers/telegram/telegram_provider.dart';

import '../fakes/fake_credentials_store.dart';
import '../fakes/fake_database_key_store.dart';
import '../fakes/fake_storage_provider.dart';
import '../fakes/fake_tdlib_bridge.dart';

/// Contract tests for [StorageProvider]. Parameterized by a factory so
/// the same suite runs against every implementation (the fake reference
/// and TelegramProvider with fakes).
///
/// These prove contract behavior, never a real TDLib connection
/// (PROJECT_RULES #14, #15).
void runStorageProviderContractTests({
  required String name,
  required StorageProvider Function() create,
  required Future<StorageProvider> Function() createAuthenticated,
}) {
  group('StorageProvider contract: $name', () {
    test('methods before initialize throw ProviderNotInitialized', () async {
      final provider = create();
      await expectLater(
        provider.authenticate(),
        throwsA(isA<ProviderNotInitialized>()),
      );
      await expectLater(
        provider.getAccountCapabilities(),
        throwsA(isA<ProviderNotInitialized>()),
      );
      await provider.dispose();
    });

    test('initialize is idempotent', () async {
      final provider = create();
      await provider.initialize();
      await provider.initialize();
      expect(provider.currentAuthState, isA<AuthUnauthenticated>());
      await provider.dispose();
    });

    test(
      'authenticate without credentials completes with AuthFailed',
      () async {
        final provider = create();
        await provider.initialize();
        final state = await provider.authenticate();
        expect(state, isA<AuthFailed>());
        expect((state as AuthFailed).error, isA<ProviderUnauthenticated>());
        await provider.dispose();
      },
    );

    test('capabilities before auth throw ProviderUnauthenticated', () async {
      final provider = create();
      await provider.initialize();
      await expectLater(
        provider.getAccountCapabilities(),
        throwsA(isA<ProviderUnauthenticated>()),
      );
      await provider.dispose();
    });

    test('authenticated provider reports capabilities', () async {
      final provider = await createAuthenticated();
      final caps = await provider.getAccountCapabilities();
      expect(caps.accountId.value, isNotEmpty);
      expect(caps.supportsStreaming, CapabilityStatus.unknown);
      await provider.dispose();
    });

    test('dispose is terminal', () async {
      final provider = await createAuthenticated();
      await provider.dispose();
      await expectLater(provider.initialize(), throwsA(isA<ProviderUnknown>()));
      await expectLater(
        provider.authenticate(),
        throwsA(isA<ProviderUnknown>()),
      );
      await provider.dispose();
    });
  });
}

void main() {
  runStorageProviderContractTests(
    name: 'FakeStorageProvider',
    create: () => FakeStorageProvider(),
    createAuthenticated: () async {
      final provider = FakeStorageProvider()..hasCredentials = true;
      await provider.initialize();
      await provider.authenticate();
      return provider;
    },
  );

  runStorageProviderContractTests(
    name: 'TelegramProvider (fake bridge)',
    create: () => TelegramProvider(
      bridge: FakeTdlibBridge(),
      credentialsStore: FakeTelegramCredentialsStore(),
      databaseKeyStore: FakeTdlibDatabaseKeyStore(),
      databaseDirectory: 'db',
      filesDirectory: 'db/files',
    ),
    createAuthenticated: () async {
      final bridge = FakeTdlibBridge();
      final store = FakeTelegramCredentialsStore()
        ..apiId = 12345
        ..apiHash = 'hash';
      final provider = TelegramProvider(
        bridge: bridge,
        credentialsStore: store,
        databaseKeyStore: FakeTdlibDatabaseKeyStore(),
        databaseDirectory: 'db',
        filesDirectory: 'db/files',
      );
      await provider.initialize();
      bridge.onSetTdlibParameters = bridge.emitReady;
      await provider.authenticate();
      return provider;
    },
  );
}
