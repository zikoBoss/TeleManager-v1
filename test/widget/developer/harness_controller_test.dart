import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemanager/features/developer/harness/harness_controller.dart';
import 'package:telemanager/features/developer/harness/harness_event_log.dart';
import 'package:telemanager/providers/auth_state.dart';
import 'package:telemanager/providers/telegram/tdlib_method_channel.dart';

import '../../fakes/fake_credentials_store.dart';
import '../../fakes/fake_database_key_store.dart';
import '../../fakes/fake_harness_test_hooks.dart';
import '../../fakes/fake_tdlib_bridge.dart';

HarnessController createController({
  FakeTdlibBridge? bridge,
  FakeHarnessTestHooks? testHooks,
  FakeTelegramCredentialsStore? store,
  FakeTdlibDatabaseKeyStore? keyStore,
  String databaseDirectory = 'db',
  String filesDirectory = 'db/files',
}) {
  return HarnessController(
    bridge: bridge ?? FakeTdlibBridge(),
    testHooks: testHooks ?? FakeHarnessTestHooks(),
    credentialsStore: store ?? FakeTelegramCredentialsStore(),
    databaseKeyStore: keyStore ?? FakeTdlibDatabaseKeyStore(),
    databaseDirectory: databaseDirectory,
    filesDirectory: filesDirectory,
  );
}

FakeTelegramCredentialsStore storedCredentials() {
  return FakeTelegramCredentialsStore()
    ..apiId = 12345
    ..apiHash = 'hash';
}

void main() {
  test('Harness event log includes millisecond timestamps', () {
    final log = HarnessEventLog()..add('safe event');
    expect(
      log.toText(),
      matches(RegExp(r'^\[\d{2}:\d{2}:\d{2}\.\d{3}\] safe event$')),
    );
  });

  group('HarnessController', () {
    test('initialize creates and initializes the provider', () async {
      final controller = createController();
      await controller.initialize();
      expect(controller.providerInitialized, isTrue);
      expect(controller.authState, isA<AuthUnauthenticated>());
      expect(controller.keyStatus, 'missing');
      controller.dispose();
    });

    test(
      'authenticate reaches Authenticated and the log has no my_id',
      () async {
        final bridge = FakeTdlibBridge();
        final controller = createController(
          bridge: bridge,
          store: storedCredentials(),
        );
        await controller.initialize();
        bridge.onSetTdlibParameters = bridge.emitReady;
        await controller.authenticate();
        expect(controller.authState, isA<AuthAuthenticated>());
        expect(controller.myId, '8934661485');
        expect(controller.myIdMatchesExpected, isTrue);
        // my_id is shown on the screen, never written to the log.
        expect(controller.eventLog.toText(), isNot(contains('8934661485')));
        expect(
          controller.eventLog.toText(),
          contains('my_id matches expected: yes'),
        );
        controller.dispose();
      },
    );

    test('the log never contains the QR link', () async {
      final bridge = FakeTdlibBridge();
      final controller = createController(bridge: bridge);
      await controller.initialize();
      const link = 'tg://login?token=secret123';
      bridge.emitAuthUpdate(
        const TdlibAuthUpdate(
          state: 'AuthorizationStateWaitOtherDeviceConfirmation',
          qrLink: link,
        ),
      );
      await pumpEventQueue();
      expect(controller.qrLink, link);
      expect(controller.eventLog.toText(), isNot(contains(link)));
      expect(controller.eventLog.toText(), isNot(contains('secret123')));
      expect(
        controller.eventLog.toText(),
        contains('AwaitingInput (other device — QR)'),
      );
      controller.dispose();
    });

    test(
      'reset refuses pending request without deleting database or key',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'telemanager-harness-pending-',
        );
        final databaseDirectory = '${root.path}/tdlib';
        final bridge = FakeTdlibBridge();
        final keyBytes = Uint8List.fromList(List.generate(32, (i) => i));
        final keyStore = FakeTdlibDatabaseKeyStore()..storedKey = keyBytes;
        HarnessController? controller;
        Future<void>? hung;
        try {
          await Directory(databaseDirectory).create(recursive: true);
          final marker = File('$databaseDirectory/marker');
          await marker.writeAsString('test database remains');
          final activeController = createController(
            bridge: bridge,
            keyStore: keyStore,
            databaseDirectory: databaseDirectory,
            filesDirectory: '$databaseDirectory/files',
          );
          controller = activeController;
          await activeController.initialize();
          bridge.hangNextCall(TdlibBridge.setTdlibParametersMethod);
          hung = bridge.setTdlibParameters(
            apiId: 1,
            apiHash: 'h',
            databaseDirectory: databaseDirectory,
            filesDirectory: '$databaseDirectory/files',
            applicationVersion: '1.0.0',
            databaseEncryptionKey: Uint8List(32),
          );
          await pumpEventQueue();
          bridge.timeoutHungCall(TdlibBridge.setTdlibParametersMethod);
          await activeController.refreshPending();
          await activeController.resetTestSession();
          expect(activeController.lastActionResult, contains('refused'));
          expect(
            activeController.lastActionResult,
            contains('storage unchanged=yes'),
          );
          expect(await marker.readAsString(), 'test database remains');
          expect(await Directory(databaseDirectory).exists(), isTrue);
          expect(activeController.databaseStatus, 'present');
          expect(activeController.keyStatus, 'present');
          expect(keyStore.clearKeyCalls, 0);
          expect(keyStore.storedKey, same(keyBytes));
          bridge.resolveHungCall(TdlibBridge.setTdlibParametersMethod);
          await hung;
          await activeController.disposeProvider();
          activeController.dispose();
          controller = null;
        } finally {
          bridge.resolveHungCall(TdlibBridge.setTdlibParametersMethod);
          final hungCall = hung;
          if (hungCall != null) await hungCall;
          if (controller != null) {
            await controller.disposeProvider();
            controller.dispose();
          }
          await root.delete(recursive: true);
        }
      },
    );

    test('reset deletes the database and key and verifies', () async {
      final dbDir = await Directory.systemTemp.createTemp(
        'telemanager-harness-',
      );
      try {
        await Directory('${dbDir.path}/tdlib').create(recursive: true);
        await File('${dbDir.path}/tdlib/tdlib.db').writeAsString('x');
        final keyStore = FakeTdlibDatabaseKeyStore()..storedKey = Uint8List(32);
        final controller = HarnessController(
          bridge: FakeTdlibBridge(),
          testHooks: FakeHarnessTestHooks(),
          credentialsStore: FakeTelegramCredentialsStore(),
          databaseKeyStore: keyStore,
          databaseDirectory: '${dbDir.path}/tdlib',
          filesDirectory: '${dbDir.path}/tdlib/files',
        );
        await controller.initialize();
        await controller.resetTestSession();
        expect(controller.lastActionResult, contains('verified'));
        expect(await Directory('${dbDir.path}/tdlib').exists(), isFalse);
        expect(await keyStore.readKey(), isNull);
        expect(keyStore.clearKeyCalls, 1);
        expect(controller.keyStatus, 'missing');
        expect(controller.databaseStatus, 'missing');
        expect(controller.busy, isFalse);
        controller.dispose();
      } finally {
        await dbDir.delete(recursive: true);
      }
    });

    test(
      'reset keeps busy until key and database verification finishes',
      () async {
        final dbDir = await Directory.systemTemp.createTemp(
          'telemanager-harness-busy-',
        );
        final enteredClear = Completer<void>();
        final releaseClear = Completer<void>();
        Future<void>? reset;
        final keyStore = FakeTdlibDatabaseKeyStore()
          ..storedKey = Uint8List(32)
          ..beforeClearKey = () async {
            if (!enteredClear.isCompleted) enteredClear.complete();
            await releaseClear.future;
          };
        final controller = HarnessController(
          bridge: FakeTdlibBridge(),
          testHooks: FakeHarnessTestHooks(),
          credentialsStore: FakeTelegramCredentialsStore(),
          databaseKeyStore: keyStore,
          databaseDirectory: '${dbDir.path}/tdlib',
          filesDirectory: '${dbDir.path}/tdlib/files',
        );
        try {
          await Directory('${dbDir.path}/tdlib').create(recursive: true);
          await controller.initialize();
          reset = controller.resetTestSession();
          await enteredClear.future;
          expect(controller.busy, isTrue);
          await controller.resetTestSession();
          expect(controller.busy, isTrue);
          expect(keyStore.clearKeyCalls, 1);
          releaseClear.complete();
          await reset;
          expect(controller.busy, isFalse);
        } finally {
          if (!releaseClear.isCompleted) releaseClear.complete();
          final resetFuture = reset;
          if (resetFuture != null) await resetFuture;
          controller.dispose();
          await dbDir.delete(recursive: true);
        }
      },
    );

    test('setReplyDelay arms a delay via the test hooks', () async {
      final testHooks = FakeHarnessTestHooks();
      final controller = createController(testHooks: testHooks);
      await controller.initialize();
      await controller.setReplyDelay('setTdlibParameters', 15000);
      expect(testHooks.delays['setTdlibParameters'], 15000);
      await controller.clearReplyDelays();
      expect(testHooks.delays.isEmpty, isTrue);
      controller.dispose();
    });

    test('refreshSendCounts exposes the bridge send counts', () async {
      final testHooks = FakeHarnessTestHooks()
        ..sendCounts = {'setTdlibParameters': 1, 'logOut': 0};
      final controller = createController(testHooks: testHooks);
      await controller.initialize();
      await controller.refreshSendCounts();
      expect(controller.sendCounts['setTdlibParameters'], 1);
      expect(controller.sendCounts['logOut'], 0);
      controller.dispose();
    });

    test(
      'refreshDiagnostics updates credentials, key status, and counts',
      () async {
        final store = storedCredentials();
        final keyStore = FakeTdlibDatabaseKeyStore()..storedKey = Uint8List(32);
        final testHooks = FakeHarnessTestHooks()
          ..sendCounts = {'setTdlibParameters': 1};
        final controller = createController(
          store: store,
          keyStore: keyStore,
          testHooks: testHooks,
        );
        await controller.initialize();
        expect(controller.credentialsSaved, isTrue);
        expect(controller.keyStatus, 'present');

        store.apiId = null;
        store.apiHash = null;
        keyStore.storedKey = null;
        testHooks.sendCounts = {'setTdlibParameters': 2, 'logOut': 1};
        await controller.refreshDiagnostics();

        expect(controller.credentialsSaved, isFalse);
        expect(controller.keyStatus, 'missing');
        expect(controller.sendCounts['setTdlibParameters'], 2);
        expect(controller.sendCounts['logOut'], 1);
        expect(controller.lastActionResult, 'diagnostics refreshed');
        controller.dispose();
      },
    );

    testWidgets('monitors pending transitions and send count automatically', (
      tester,
    ) async {
      final bridge = FakeTdlibBridge();
      final testHooks = FakeHarnessTestHooks()
        ..sendCounts = {'setTdlibParameters': 1};
      final controller = createController(
        bridge: bridge,
        testHooks: testHooks,
        store: storedCredentials(),
      );
      await controller.initialize();
      bridge.hangNextCall(TdlibBridge.setTdlibParametersMethod);
      bridge.onSetTdlibParameters = () {
        bridge.emitAuthUpdate(
          const TdlibAuthUpdate(state: 'AuthorizationStateWaitPhoneNumber'),
        );
      };
      final authenticate = controller.authenticate();
      await pumpEventQueue();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        controller.eventLog.toText(),
        contains(
          'request setTdlibParameters observed: pending=yes, unresolved=no',
        ),
      );
      expect(controller.eventLog.toText(), contains('sends=1'));

      bridge.timeoutHungCall(TdlibBridge.setTdlibParametersMethod);
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        controller.eventLog.toText(),
        contains(
          'request setTdlibParameters observed: pending=yes, unresolved=yes',
        ),
      );

      bridge.resolveHungCall(TdlibBridge.setTdlibParametersMethod);
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        controller.eventLog.toText(),
        contains(
          'request setTdlibParameters observed: pending=no, unresolved=no',
        ),
      );
      expect(
        controller.eventLog.toText(),
        matches(r'since-first-observed=\d+ms'),
      );
      bridge.emitReady();
      await authenticate;
      await controller.disposeProvider();
      controller.dispose();
    });

    test('saveCredentials stores them and reports saved (no values)', () async {
      final store = FakeTelegramCredentialsStore();
      final controller = createController(store: store);
      await controller.initialize();
      expect(controller.credentialsSaved, isFalse);
      await controller.saveCredentials(12345, 'hash');
      expect(controller.credentialsSaved, isTrue);
      expect(store.apiId, 12345);
      expect(store.apiHash, 'hash');
      // The values never appear in the log.
      expect(controller.eventLog.toText(), isNot(contains('12345')));
      expect(controller.eventLog.toText(), isNot(contains('hash')));
      controller.dispose();
    });
  });
}
