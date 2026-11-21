import 'package:flutter_test/flutter_test.dart';
import 'package:telemanager/providers/auth_state.dart';
import 'package:telemanager/providers/capability_status.dart';
import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/telegram/tdlib_method_channel.dart';
import 'package:telemanager/providers/telegram/telegram_auth_steps.dart';
import 'package:telemanager/providers/telegram/telegram_provider.dart';

import '../../fakes/fake_credentials_store.dart';
import '../../fakes/fake_tdlib_bridge.dart';

TelegramProvider createProvider({
  FakeTdlibBridge? bridge,
  FakeTelegramCredentialsStore? store,
  Duration closeWaitTimeout = const Duration(seconds: 8),
}) {
  return TelegramProvider(
    bridge: bridge ?? FakeTdlibBridge(),
    credentialsStore: store ?? FakeTelegramCredentialsStore(),
    databaseDirectory: 'db',
    filesDirectory: 'db/files',
    closeWaitTimeout: closeWaitTimeout,
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
      // Resumable upload: unsupported (no TDLib mechanism to resume
      // a message send). Resumable download: conditional (the offset
      // API exists, TeleManager does not use it yet — Task 11).
      // Streaming: unknown (untested, PROJECT_RULES #18).
      expect(caps.supportsResumableUpload, CapabilityStatus.unsupported);
      expect(caps.supportsResumableDownload, CapabilityStatus.conditional);
      expect(caps.supportsStreaming, CapabilityStatus.unknown);
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
      'signOut waits for Closed, re-initializes, and re-auth works',
      () async {
        final bridge = FakeTdlibBridge();
        final provider = createProvider(
          bridge: bridge,
          store: storedCredentials(),
        );
        await provider.initialize();
        bridge.onSetTdlibParameters = bridge.emitReady;
        final firstAuth = await provider.authenticate();
        expect(firstAuth, isA<AuthAuthenticated>());
        expect(provider.currentAuthState, isA<AuthAuthenticated>());
        expect(bridge.initializeCalls, 1);
        expect(bridge.setTdlibParametersCalls, 1);

        // Start signOut and let it reach the Closed wait; the client
        // must NOT be re-created yet.
        final signOutFuture = provider.signOut();
        await pumpEventQueue();
        expect(bridge.logOutCalls, 1);
        expect(bridge.initializeCalls, 1);
        expect(bridge.clientAlive, isFalse);
        // Drive Closed: signOut completes and re-creates the client.
        bridge.emitAuthUpdate(
          const TdlibAuthUpdate(state: 'AuthorizationStateClosed'),
        );
        await signOutFuture;
        expect(bridge.initializeCalls, 2);
        expect(bridge.clientAlive, isTrue);
        expect(provider.currentAuthState, isA<AuthUnauthenticated>());

        // Re-authenticate on the new client (no app restart).
        bridge.onSetTdlibParameters = bridge.emitReady;
        final secondAuth = await provider.authenticate();
        expect(secondAuth, isA<AuthAuthenticated>());
        expect(
          (secondAuth as AuthAuthenticated).account.accountId.value,
          '8934661485',
        );
        expect(bridge.setTdlibParametersCalls, 2);
        await provider.dispose();
      },
    );

    test(
      'signOut skips the Closed wait when Closed arrives during logOut',
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
        // Closed arrives while signOut is awaiting logOut: the wait
        // must be skipped (the state is already Unauthenticated) and
        // the client still re-created.
        bridge.onLogOut = () => bridge.emitAuthUpdate(
          const TdlibAuthUpdate(state: 'AuthorizationStateClosed'),
        );
        await provider.signOut();
        expect(bridge.logOutCalls, 1);
        expect(bridge.initializeCalls, 2);
        expect(bridge.clientAlive, isTrue);
        expect(provider.currentAuthState, isA<AuthUnauthenticated>());
        await provider.dispose();
      },
    );

    test('signOut times out without Closed, does not re-initialize, '
        'and leaves the provider unusable', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
        closeWaitTimeout: const Duration(milliseconds: 50),
      );
      await provider.initialize();
      bridge.onSetTdlibParameters = bridge.emitReady;
      await provider.authenticate();
      expect(provider.currentAuthState, isA<AuthAuthenticated>());
      // No Closed is ever emitted: the wait must time out, throw,
      // and never re-initialize (the old client may still be
      // closing). Recovery is dispose + a new provider.
      await expectLater(provider.signOut(), throwsA(isA<ProviderNetwork>()));
      expect(bridge.logOutCalls, 1);
      expect(bridge.initializeCalls, 1);
      expect(bridge.clientAlive, isFalse);
      // The provider is unusable after the unresolved timeout:
      // every later call that would touch the bridge is refused
      // (before sending anything), even though no Closed arrived.
      await expectLater(
        provider.authenticate(),
        throwsA(
          isA<ProviderUnknown>().having(
            (e) => e.providerCode,
            'providerCode',
            'provider_unusable_after_logout',
          ),
        ),
      );
      await expectLater(provider.signOut(), throwsA(isA<ProviderUnknown>()));
      await expectLater(provider.initialize(), throwsA(isA<ProviderUnknown>()));
      await provider.dispose();
    });

    test('setTdlibParameters timeout is unresolved, then a late Ok moves '
        'the state to AwaitingInput', () async {
      final bridge = FakeTdlibBridge()
        ..failNextSetTdlibParameters = const ProviderRequestUnresolved(
          'setTdlibParameters',
        );
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      // The timeout is not a failure: authenticate completes with
      // AuthFailed carrying the unresolved error (not ProviderNetwork).
      final state = await provider.authenticate();
      expect(state, isA<AuthFailed>());
      final error = (state as AuthFailed).error;
      expect(error, isA<ProviderRequestUnresolved>());
      expect((error as ProviderRequestUnresolved).method, 'setTdlibParameters');
      expect(bridge.setTdlibParametersCalls, 1);
      // The late Ok arrives as a state update (the parameters were
      // applied): the state machine moves to AwaitingInput. The
      // provider does not retry on its own.
      bridge.emitAuthUpdate(
        const TdlibAuthUpdate(state: 'AuthorizationStateWaitPhoneNumber'),
      );
      await pumpEventQueue();
      expect(provider.currentAuthState, isA<AuthAwaitingInput>());
      expect(bridge.setTdlibParametersCalls, 1);
      await provider.dispose();
    });

    test('setTdlibParameters timeout then no update leaves the state '
        'unchanged', () async {
      final bridge = FakeTdlibBridge()
        ..failNextSetTdlibParameters = const ProviderRequestUnresolved(
          'setTdlibParameters',
        );
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      final state = await provider.authenticate();
      expect(state, isA<AuthFailed>());
      expect((state as AuthFailed).error, isA<ProviderRequestUnresolved>());
      // A late Error produces no state update (the bridge discards
      // the late method result, covered by the real-bridge test),
      // so the state stays AuthFailed with the unresolved error.
      await pumpEventQueue();
      expect(provider.currentAuthState, isA<AuthFailed>());
      expect(
        (provider.currentAuthState as AuthFailed).error,
        isA<ProviderRequestUnresolved>(),
      );
      expect(bridge.setTdlibParametersCalls, 1);
      await provider.dispose();
    });

    test('retry is refused while the previous request is unresolved', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      // Hang the first submitCode (the native request is
      // outstanding), then mark it unresolved (the Dart timeout
      // fired). A retry must be refused without sending.
      bridge.hangNextCall(TdlibBridge.checkAuthenticationCodeMethod);
      final first = provider.submitCode('12345');
      await pumpEventQueue();
      expect(bridge.checkCodeCalls, 1);
      expect(
        bridge.hasPendingRequest(TdlibBridge.checkAuthenticationCodeMethod),
        isTrue,
      );
      bridge.timeoutHungCall(TdlibBridge.checkAuthenticationCodeMethod);
      expect(
        bridge.isRequestUnresolved(TdlibBridge.checkAuthenticationCodeMethod),
        isTrue,
      );
      await expectLater(
        provider.submitCode('12345'),
        throwsA(isA<ProviderRequestUnresolved>()),
      );
      expect(bridge.checkCodeCalls, 1);
      // The late native reply arrives: the entry is cleared and a
      // retry is allowed.
      bridge.resolveHungCall(TdlibBridge.checkAuthenticationCodeMethod);
      await first;
      expect(
        bridge.hasPendingRequest(TdlibBridge.checkAuthenticationCodeMethod),
        isFalse,
      );
      await provider.submitCode('12345');
      expect(bridge.checkCodeCalls, 2);
      await provider.dispose();
    });

    test('a correct auth update after a timeout still authenticates', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      // Drive the flow to WaitCode first (so submitCode is valid).
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
      expect(provider.currentAuthState, isA<AuthAwaitingInput>());
      // submitCode times out, but the code was accepted: Ready
      // arrives and the provider authenticates (the timeout must
      // not block a correct update).
      bridge.hangNextCall(TdlibBridge.checkAuthenticationCodeMethod);
      final submitFuture = provider.submitCode('12345');
      await pumpEventQueue();
      bridge.resolveHungCall(
        TdlibBridge.checkAuthenticationCodeMethod,
        error: const ProviderRequestUnresolved('checkAuthenticationCode'),
      );
      await expectLater(
        submitFuture,
        throwsA(isA<ProviderRequestUnresolved>()),
      );
      bridge.emitReady();
      await pumpEventQueue();
      expect(provider.currentAuthState, isA<AuthAuthenticated>());
      await provider.dispose();
    });

    test('auth updates after dispose are ignored', () async {
      final bridge = FakeTdlibBridge()..closeStreamsOnDispose = false;
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      bridge.onSetTdlibParameters = bridge.emitReady;
      await provider.authenticate();
      expect(provider.currentAuthState, isA<AuthAuthenticated>());
      await provider.dispose();
      // The fake's streams are still open (closeStreamsOnDispose is
      // false), so an update can still be emitted — but the provider
      // cancelled its subscription in dispose(), so it must not move.
      bridge.emitAuthUpdate(
        const TdlibAuthUpdate(state: 'AuthorizationStateWaitCode'),
      );
      await pumpEventQueue();
      expect(provider.currentAuthState, isA<AuthAuthenticated>());
    });

    test(
      'logOut timeout then a late Closed leaves the provider unusable',
      () async {
        final bridge = FakeTdlibBridge()
          ..failNextLogOut = const ProviderRequestUnresolved('logOut');
        final provider = createProvider(
          bridge: bridge,
          store: storedCredentials(),
        );
        await provider.initialize();
        bridge.onSetTdlibParameters = bridge.emitReady;
        await provider.authenticate();
        expect(provider.currentAuthState, isA<AuthAuthenticated>());
        // logOut times out: signOut throws the unresolved error and
        // the provider becomes unusable.
        await expectLater(
          provider.signOut(),
          throwsA(isA<ProviderRequestUnresolved>()),
        );
        expect(bridge.logOutCalls, 1);
        expect(bridge.initializeCalls, 1);
        // The late Closed still arrives and the state becomes
        // Unauthenticated (the state machine stays truthful) — but
        // the provider is NOT reusable: the late Closed alone is not
        // enough.
        bridge.emitAuthUpdate(
          const TdlibAuthUpdate(state: 'AuthorizationStateClosed'),
        );
        await pumpEventQueue();
        expect(provider.currentAuthState, isA<AuthUnauthenticated>());
        await expectLater(
          provider.authenticate(),
          throwsA(isA<ProviderUnknown>()),
        );
        await expectLater(provider.signOut(), throwsA(isA<ProviderUnknown>()));
        await expectLater(
          provider.initialize(),
          throwsA(isA<ProviderUnknown>()),
        );
        // dispose() still works (it is never blocked by the flag).
        await provider.dispose();
      },
    );

    test(
      'all reuse is refused after a logOut timeout, before dispose',
      () async {
        final bridge = FakeTdlibBridge()
          ..failNextLogOut = const ProviderRequestUnresolved('logOut');
        final provider = createProvider(
          bridge: bridge,
          store: storedCredentials(),
        );
        await provider.initialize();
        bridge.onSetTdlibParameters = bridge.emitReady;
        await provider.authenticate();
        await expectLater(
          provider.signOut(),
          throwsA(isA<ProviderRequestUnresolved>()),
        );
        // The state is still Authenticated (no Closed arrived), yet
        // every method that would touch the bridge is refused.
        expect(provider.currentAuthState, isA<AuthAuthenticated>());
        await expectLater(
          provider.getAccountCapabilities(),
          throwsA(isA<ProviderUnknown>()),
        );
        await expectLater(
          provider.submitPhoneNumber('+123'),
          throwsA(isA<ProviderUnknown>()),
        );
        await expectLater(
          provider.submitCode('12345'),
          throwsA(isA<ProviderUnknown>()),
        );
        await expectLater(
          provider.submitPassword('secret'),
          throwsA(isA<ProviderUnknown>()),
        );
        await expectLater(
          provider.requestQrLogin(),
          throwsA(isA<ProviderUnknown>()),
        );
        // No bridge call was sent by any of the refused methods.
        expect(bridge.setPhoneNumberCalls, 0);
        expect(bridge.checkCodeCalls, 0);
        expect(bridge.checkPasswordCalls, 0);
        expect(bridge.requestQrCalls, 0);
        await provider.dispose();
      },
    );

    test('concurrent signOut calls return the identical Future', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      bridge.onSetTdlibParameters = bridge.emitReady;
      await provider.authenticate();
      final f1 = provider.signOut();
      final f2 = provider.signOut();
      expect(identical(f1, f2), isTrue);
      await pumpEventQueue(); // let signOut reach the Closed wait
      expect(bridge.logOutCalls, 1);
      expect(bridge.initializeCalls, 1);
      bridge.emitAuthUpdate(
        const TdlibAuthUpdate(state: 'AuthorizationStateClosed'),
      );
      await f1;
      await f2;
      expect(bridge.logOutCalls, 1);
      expect(bridge.initializeCalls, 2);
      await provider.dispose();
    });

    test(
      'concurrent signOut calls share the Closed-wait timeout failure',
      () async {
        final bridge = FakeTdlibBridge();
        final provider = createProvider(
          bridge: bridge,
          store: storedCredentials(),
          closeWaitTimeout: const Duration(milliseconds: 50),
        );
        await provider.initialize();
        bridge.onSetTdlibParameters = bridge.emitReady;
        await provider.authenticate();
        final f1 = provider.signOut();
        final f2 = provider.signOut();
        expect(identical(f1, f2), isTrue);
        await expectLater(f1, throwsA(isA<ProviderNetwork>()));
        await expectLater(f2, throwsA(isA<ProviderNetwork>()));
        expect(bridge.logOutCalls, 1);
        expect(bridge.initializeCalls, 1);
        await provider.dispose();
      },
    );

    test('concurrent signOut calls share the logOut timeout failure', () async {
      final bridge = FakeTdlibBridge()
        ..failNextLogOut = const ProviderRequestUnresolved('logOut');
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      bridge.onSetTdlibParameters = bridge.emitReady;
      await provider.authenticate();
      final f1 = provider.signOut();
      final f2 = provider.signOut();
      expect(identical(f1, f2), isTrue);
      await expectLater(f1, throwsA(isA<ProviderRequestUnresolved>()));
      await expectLater(f2, throwsA(isA<ProviderRequestUnresolved>()));
      expect(bridge.logOutCalls, 1);
      expect(bridge.initializeCalls, 1);
      // A later call is a NEW operation (the first one finished),
      // so it is refused as unusable, not a share of f1.
      await expectLater(
        provider.signOut(),
        throwsA(
          isA<ProviderUnknown>().having(
            (e) => e.providerCode,
            'providerCode',
            'provider_unusable_after_logout',
          ),
        ),
      );
      await provider.dispose();
    });

    test(
      'second signOut during dispose returns the identical Future',
      () async {
        final bridge = FakeTdlibBridge();
        final provider = createProvider(
          bridge: bridge,
          store: storedCredentials(),
        );
        await provider.initialize();
        bridge.onSetTdlibParameters = bridge.emitReady;
        await provider.authenticate();
        // signOut waits for Closed (never emitted).
        final f1 = provider.signOut();
        await pumpEventQueue(); // let signOut reach the Closed wait
        // dispose() is called but NOT awaited: synchronously after
        // it, the in-flight signOut must still be returned (identical),
        // not a new Future.error from the disposed guard.
        final disposeFuture = provider.dispose();
        final f2 = provider.signOut();
        expect(identical(f1, f2), isTrue);
        await disposeFuture;
        await expectLater(f1, throwsA(isA<ProviderUnknown>()));
        await expectLater(f2, throwsA(isA<ProviderUnknown>()));
      },
    );

    test('dispose during in-flight logOut fails signOut promptly', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      bridge.onSetTdlibParameters = bridge.emitReady;
      await provider.authenticate();
      // Hang logOut (the native request is outstanding).
      bridge.hangNextCall(TdlibBridge.logOutMethod);
      final signOutFuture = provider.signOut();
      await pumpEventQueue(); // let signOut reach the logOut await
      await provider.dispose();
      // The late native reply arrives (logOut completes after
      // dispose): signOut must fail promptly with provider_disposed
      // (via the _throwIfDisposed check after logOut), not wait
      // 8s for a Closed that will never be delivered.
      bridge.resolveHungCall(TdlibBridge.logOutMethod);
      await expectLater(
        signOutFuture,
        throwsA(
          isA<ProviderUnknown>().having(
            (e) => e.providerCode,
            'providerCode',
            'provider_disposed',
          ),
        ),
      );
    });

    test('_onReady after dispose does not emit Authenticated', () async {
      final bridge = FakeTdlibBridge();
      final provider = createProvider(
        bridge: bridge,
        store: storedCredentials(),
      );
      await provider.initialize();
      // Hang getMyId: Ready arrives but the account id is not read yet.
      bridge.hangNextCall(TdlibBridge.getMyIdMethod);
      bridge.emitReady();
      await pumpEventQueue(); // let _onReady reach the getMyId await
      await provider.dispose();
      // The late my_id arrives after dispose: it must be dropped,
      // not emitted as Authenticated on a dead provider.
      bridge.resolveHungCall(TdlibBridge.getMyIdMethod);
      await pumpEventQueue();
      expect(provider.currentAuthState, isA<AuthUnauthenticated>());
    });

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
