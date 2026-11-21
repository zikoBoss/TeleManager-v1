import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/telegram/tdlib_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('telemanager.tdlib');

  group('MethodChannelTdlibBridge', () {
    late MethodChannelTdlibBridge bridge;
    late Map<String, Completer<Object?>> pendingCalls;
    late List<String> calls;

    setUp(() {
      pendingCalls = {};
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call.method);
            final pending = pendingCalls[call.method];
            if (pending != null) return pending.future;
            return null;
          });
      // A 50ms override so the unresolved path triggers quickly. The
      // production timeouts (10s/30s) are unchanged.
      bridge = MethodChannelTdlibBridge(
        channel,
        const Duration(milliseconds: 50),
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      // Complete any hung calls so the test process does not keep
      // them pending.
      for (final completer in pendingCalls.values) {
        if (!completer.isCompleted) completer.complete();
      }
    });

    void hangCall(String method) {
      pendingCalls[method] = Completer<Object?>();
    }

    Future<void> setParameters() => bridge.setTdlibParameters(
      apiId: 123,
      apiHash: 'hash',
      databaseDirectory: '/tmp/db',
      filesDirectory: '/tmp/files',
      applicationVersion: '1.0.0',
      databaseEncryptionKey: Uint8List(32),
    );

    test('a timeout marks the request unresolved', () async {
      hangCall(TdlibBridge.setTdlibParametersMethod);
      final future = setParameters();
      await pumpEventQueue();
      expect(
        bridge.hasPendingRequest(TdlibBridge.setTdlibParametersMethod),
        isTrue,
      );
      expect(
        bridge.isRequestUnresolved(TdlibBridge.setTdlibParametersMethod),
        isFalse,
      );
      // The timeout fires: the error is ProviderRequestUnresolved,
      // not ProviderNetwork, and the entry stays (the native request
      // is still outstanding).
      await expectLater(future, throwsA(isA<ProviderRequestUnresolved>()));
      expect(
        bridge.hasPendingRequest(TdlibBridge.setTdlibParametersMethod),
        isTrue,
      );
      expect(
        bridge.isRequestUnresolved(TdlibBridge.setTdlibParametersMethod),
        isTrue,
      );
      // The late Ok arrives: the entry is cleared.
      pendingCalls[TdlibBridge.setTdlibParametersMethod]!.complete();
      await pumpEventQueue();
      expect(
        bridge.hasPendingRequest(TdlibBridge.setTdlibParametersMethod),
        isFalse,
      );
      expect(
        bridge.isRequestUnresolved(TdlibBridge.setTdlibParametersMethod),
        isFalse,
      );
    });

    test('a late Error clears the entry without surfacing', () async {
      hangCall(TdlibBridge.setTdlibParametersMethod);
      final future = setParameters();
      await pumpEventQueue();
      await expectLater(future, throwsA(isA<ProviderRequestUnresolved>()));
      expect(
        bridge.isRequestUnresolved(TdlibBridge.setTdlibParametersMethod),
        isTrue,
      );
      // The late native Error arrives: it must not surface (the
      // future already threw), and the entry must be cleared.
      pendingCalls[TdlibBridge.setTdlibParametersMethod]!.completeError(
        PlatformException(code: '400', message: 'Bad request.'),
      );
      await pumpEventQueue();
      expect(
        bridge.hasPendingRequest(TdlibBridge.setTdlibParametersMethod),
        isFalse,
      );
      expect(
        bridge.isRequestUnresolved(TdlibBridge.setTdlibParametersMethod),
        isFalse,
      );
    });

    test(
      'two requests of the same method have independent identities',
      () async {
        // Hang the first call.
        final firstCompleter = Completer<Object?>();
        pendingCalls[TdlibBridge.setTdlibParametersMethod] = firstCompleter;
        final first = setParameters();
        await pumpEventQueue();
        // Start a second call of the same method while the first is
        // outstanding (the provider-level guard would refuse this,
        // but the bridge tracks it independently).
        final secondCompleter = Completer<Object?>();
        pendingCalls[TdlibBridge.setTdlibParametersMethod] = secondCompleter;
        final second = setParameters();
        await pumpEventQueue();
        expect(calls.length, 2);
        expect(
          bridge.hasPendingRequest(TdlibBridge.setTdlibParametersMethod),
          isTrue,
        );
        // The first reply arrives: the entry must NOT be cleared,
        // because the second request is still outstanding. A
        // Set<String> implementation would remove the method name
        // here and fail this assertion.
        firstCompleter.complete();
        await first;
        await pumpEventQueue();
        expect(
          bridge.hasPendingRequest(TdlibBridge.setTdlibParametersMethod),
          isTrue,
        );
        expect(
          bridge.isRequestUnresolved(TdlibBridge.setTdlibParametersMethod),
          isFalse,
        );
        // The second reply arrives: now the entry is cleared.
        secondCompleter.complete();
        await second;
        await pumpEventQueue();
        expect(
          bridge.hasPendingRequest(TdlibBridge.setTdlibParametersMethod),
          isFalse,
        );
      },
    );

    test('a normal completion clears the entry', () async {
      // The mock returns immediately (no hang), so the call
      // completes normally and the entry is cleared.
      await setParameters();
      await pumpEventQueue();
      expect(
        bridge.hasPendingRequest(TdlibBridge.setTdlibParametersMethod),
        isFalse,
      );
      expect(
        bridge.isRequestUnresolved(TdlibBridge.setTdlibParametersMethod),
        isFalse,
      );
    });
  });
}
