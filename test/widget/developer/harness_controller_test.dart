import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemanager/features/developer/harness/harness_controller.dart';
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

    test('reset refuses while a request is pending', () async {
      final bridge = FakeTdlibBridge();
      final controller = createController(bridge: bridge);
      await controller.initialize();
      // A setTdlibParameters call hung on the bridge (a late reply
      // that has not arrived yet).
      bridge.hangNextCall(TdlibBridge.setTdlibParametersMethod);
      final hung = bridge.setTdlibParameters(
        apiId: 1,
        apiHash: 'h',
        databaseDirectory: 'db',
        filesDirectory: 'db/files',
        applicationVersion: '1.0.0',
        databaseEncryptionKey: Uint8List(32),
      );
      await pumpEventQueue();
      await controller.resetTestSession();
      expect(controller.lastActionResult, contains('refused'));
      bridge.resolveHungCall(TdlibBridge.setTdlibParametersMethod);
      await hung;
      controller.dispose();
    });

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
        controller.dispose();
      } finally {
        await dbDir.delete(recursive: true);
      }
    });

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
