import 'package:flutter_test/flutter_test.dart';
import 'package:telemanager/providers/auth_state.dart';
import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/telegram/tdlib_method_channel.dart';
import 'package:telemanager/providers/telegram/telegram_auth_steps.dart';
import 'package:telemanager/providers/telegram/telegram_provider.dart';

import '../../fakes/fake_credentials_store.dart';
import '../../fakes/fake_tdlib_bridge.dart';

TelegramProvider createProvider({
  FakeTdlibBridge? bridge,
  FakeTelegramCredentialsStore? store,
}) {
  return TelegramProvider(
    bridge: bridge ?? FakeTdlibBridge(),
    credentialsStore: store ?? FakeTelegramCredentialsStore(),
    databaseDirectory: 'db',
    filesDirectory: 'db/files',
  );
}

FakeTelegramCredentialsStore storedCredentials() {
  return FakeTelegramCredentialsStore()
    ..apiId = 12345
    ..apiHash = 'hash';
}

void main() {
  group('TelegramProvider lifecycle', () {
    test('initialize is idempotent (one native client)', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(bridge: bridge);
      await provider.initialize();
      await provider.initialize();
      expect(bridge.initializeCalls, 1);
      await provider.dispose();
    });

    test('methods before initialize throw ProviderNotInitialized', () async {
      final provider = createProvider();
      await expectLater(
        provider.authenticate(),
        throwsA(isA<ProviderNotInitialized>()),
      );
      await expectLater(
        provider.getAccountCapabilities(),
        throwsA(isA<ProviderNotInitialized>()),
      );
      await expectLater(
        provider.submitPhoneNumber('+123'),
        throwsA(isA<ProviderNotInitialized>()),
      );
      await provider.dispose();
    });

    test(
      'authenticate without credentials completes with AuthFailed',
      () async {
        final bridge = FakeTdlibBridge();
        final provider = createProvider(bridge: bridge);
        await provider.initialize();
        final state = await provider.authenticate();
        expect(state, isA<AuthFailed>());
        expect((state as AuthFailed).error, isA<ProviderUnauthenticated>());
        expect(bridge.setTdlibParametersCalls, 0);
        await provider.dispose();
      },
    );

    test(
      'authenticate with credentials reaches Authenticated with my_id',
      () async {
        final bridge = FakeTdlibBridge();
        final store = storedCredentials();
        final provider = createProvider(bridge: bridge, store: store);
        await provider.initialize();
        bridge.onSetTdlibParameters = bridge.emitReady;
        final state = await provider.authenticate();
        expect(state, isA<AuthAuthenticated>());
        final account = (state as AuthAuthenticated).account;
        expect(account.accountId.value, '8934661485');
        expect(bridge.setTdlibParametersCalls, 1);
        expect(bridge.lastApiId, 12345);
        expect(bridge.lastApiHash, 'hash');
        await provider.dispose();
      },
    );

    test('authStates emits Authenticating then Authenticated', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      final states = <AuthState>[];
      final sub = provider.authStates.listen(states.add);
      bridge.onSetTdlibParameters = bridge.emitReady;
      await provider.authenticate();
      await pumpEventQueue();
      expect(states.length, 2);
      expect(states[0], isA<AuthAuthenticating>());
      expect(states[1], isA<AuthAuthenticated>());
      await sub.cancel();
      await provider.dispose();
    });

    test('capabilities require auth and report unknown limits', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      await expectLater(
        provider.getAccountCapabilities(),
        throwsA(isA<ProviderUnauthenticated>()),
      );
      bridge.onSetTdlibParameters = bridge.emitReady;
      await provider.authenticate();
      final caps = await provider.getAccountCapabilities();
      expect(caps.accountId.value, '8934661485');
      expect(caps.maxFileSizeBytes, isNull);
      expect(caps.supportsStreaming, isFalse);
      expect(caps.supportsResumableUpload, isFalse);
      expect(caps.supportsResumableDownload, isFalse);
      expect(caps.maxConcurrentTransfers, isNull);
      await provider.dispose();
    });

    test('rejected parameters complete with AuthFailed (no throw)', () async {
      final bridge = FakeTdlibBridge()
        ..failNextSetTdlibParameters = const ProviderNetwork('x');
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      final state = await provider.authenticate();
      expect(state, isA<AuthFailed>());
      expect((state as AuthFailed).error, isA<ProviderNetwork>());
      await provider.dispose();
    });

    test('my_id 0 after Ready is AuthFailed', () async {
      final bridge = FakeTdlibBridge()..myId = 0;
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      bridge.onSetTdlibParameters = bridge.emitReady;
      final state = await provider.authenticate();
      expect(state, isA<AuthFailed>());
      final error = (state as AuthFailed).error;
      expect(error, isA<ProviderUnknown>());
      expect((error as ProviderUnknown).providerCode, 'my_id_zero');
      await provider.dispose();
    });

    test('unknown authorization state fails loudly', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      bridge.onSetTdlibParameters = () => bridge.emitAuthUpdate(
        const TdlibAuthUpdate(state: 'AuthorizationStateWaitSomethingNew'),
      );
      final state = await provider.authenticate();
      expect(state, isA<AuthFailed>());
      final error = (state as AuthFailed).error;
      expect(error, isA<ProviderUnknown>());
      expect(
        (error as ProviderUnknown).providerCode,
        'unknown_authorization_state',
      );
      await provider.dispose();
    });

    test('WaitCode maps to TelegramCodeStep with code info', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      final states = <AuthState>[];
      final sub = provider.authStates.listen(states.add);
      bridge.emitAuthUpdate(
        const TdlibAuthUpdate(
          state: 'AuthorizationStateWaitCode',
          codeInfo: {
            'type': {
              'name': 'AuthenticationCodeTypeTelegramMessage',
              'length': 5,
            },
            'nextType': null,
            'timeoutSeconds': 0,
          },
        ),
      );
      await pumpEventQueue();
      expect(states, hasLength(1));
      final step = (states.single as AuthAwaitingInput).step;
      expect(step, isA<TelegramCodeStep>());
      final codeStep = step as TelegramCodeStep;
      expect(
        codeStep.codeInfo.typeName,
        'AuthenticationCodeTypeTelegramMessage',
      );
      expect(codeStep.codeInfo.typeLength, 5);
      expect(codeStep.codeInfo.canResend, isFalse);
      await sub.cancel();
      await provider.dispose();
    });

    test(
      'signOut requests logout; Closed returns to unauthenticated',
      () async {
        final bridge = FakeTdlibBridge();
        final provider = createProvider(
          bridge: bridge,
          store: storedCredentials(),
        );
        await provider.initialize();
        bridge.onSetTdlibParameters = bridge.emitReady;
        await provider.authenticate();
        expect(provider.currentAuthState, isA<AuthAuthenticated>());
        await provider.signOut();
        expect(bridge.logOutCalls, 1);
        bridge.emitAuthUpdate(
          const TdlibAuthUpdate(state: 'AuthorizationStateClosed'),
        );
        await pumpEventQueue();
        expect(provider.currentAuthState, isA<AuthUnauthenticated>());
        await provider.dispose();
      },
    );

    test('dispose closes the native client and rejects further use', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(bridge: bridge);
      await provider.initialize();
      await provider.dispose();
      expect(bridge.closeCalls, 1);
      expect(bridge.disposeCalls, 1);
      await expectLater(provider.initialize(), throwsA(isA<ProviderUnknown>()));
      await expectLater(
        provider.authenticate(),
        throwsA(isA<ProviderUnknown>()),
      );
      await provider.dispose();
    });

    test('unsolicited TDLib errors update lastError (mapped)', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(bridge: bridge);
      await provider.initialize();
      bridge.emitError(
        const TdlibError(code: 400, message: 'PHONE_CODE_INVALID'),
      );
      await pumpEventQueue();
      expect(provider.lastError, isA<ProviderInvalidInput>());
      await provider.dispose();
    });

    test('step methods forward to the bridge', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(bridge: bridge);
      await provider.initialize();
      await provider.submitPhoneNumber('+123456789');
      await provider.submitCode('12345');
      await provider.submitPassword('secret');
      await provider.requestQrLogin();
      expect(bridge.setPhoneNumberCalls, 1);
      expect(bridge.lastPhoneNumber, '+123456789');
      expect(bridge.checkCodeCalls, 1);
      expect(bridge.lastCode, '12345');
      expect(bridge.checkPasswordCalls, 1);
      expect(bridge.requestQrCalls, 1);
      await provider.dispose();
    });
  });
}
