import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:telemanager/features/developer/harness/harness_controller.dart';
import 'package:telemanager/features/developer/harness/harness_screen.dart';
import 'package:telemanager/providers/telegram/tdlib_method_channel.dart';

import '../../fakes/fake_credentials_store.dart';
import '../../fakes/fake_database_key_store.dart';
import '../../fakes/fake_harness_test_hooks.dart';
import '../../fakes/fake_tdlib_bridge.dart';

/// Pumps frames until [condition] is true (or [maxPumps] is reached),
/// then one final pump so the last notifyListeners rebuilds.
///
/// Needed because pumpAndSettle can return while a stream-driven async
/// flow (bridge Stream -> provider -> controller) is still in flight:
/// the flow schedules no frames by itself while it awaits a stream
/// event, so pumpAndSettle thinks the tree is settled. Pumping until
/// the controller's state actually changes drives the chain to
/// completion. Test-only helper.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxPumps = 50,
}) async {
  for (var i = 0; i < maxPumps && !condition(); i++) {
    await tester.pump();
  }
  await tester.pump();
}

Future<HarnessController> createController({FakeTdlibBridge? bridge}) async {
  final controller = HarnessController(
    bridge: bridge ?? FakeTdlibBridge(),
    testHooks: FakeHarnessTestHooks(),
    credentialsStore: FakeTelegramCredentialsStore()
      ..apiId = 12345
      ..apiHash = 'hash',
    databaseKeyStore: FakeTdlibDatabaseKeyStore(),
    databaseDirectory: 'db',
    filesDirectory: 'db/files',
  );
  await controller.initialize();
  return controller;
}

void main() {
  testWidgets('the Harness screen shows state and actions', (tester) async {
    final bridge = FakeTdlibBridge();
    final controller = await createController(bridge: bridge);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: HarnessScreen(controller: controller)),
    );
    await tester.pump();
    expect(find.textContaining('Auth: AuthUnauthenticated'), findsOneWidget);
    expect(find.text('Authenticate'), findsOneWidget);
    expect(find.text('Sign Out'), findsOneWidget);
    expect(find.text('Dispose Provider'), findsOneWidget);
    expect(find.text('Create New Provider'), findsOneWidget);
    expect(find.text('Reset Test Session'), findsOneWidget);
    expect(find.text('Arm D1 (15s)'), findsOneWidget);
    expect(find.text('Arm D3 (35s)'), findsOneWidget);
    // Authenticate and verify the screen shows my_id.
    bridge.onSetTdlibParameters = bridge.emitReady;
    await tester.tap(find.text('Authenticate'));
    // The tap starts authenticate() fire-and-forget. The flow is
    // driven by a broadcast stream + unawaited async work (Ready ->
    // getMyId), which FakeAsync's pump() does not flush (verified:
    // 50 pumps leave the flow stuck at AuthAuthenticating, while real
    // async completes it). Let real async run until the controller
    // reports the account, then rebuild.
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((controller.myId == null || controller.busy) &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(find.textContaining('my_id: 8934661485'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    await pumpEventQueue();
    await tester.pump();
    expect(controller.lastActionResult, 'diagnostics refreshed');
  });

  testWidgets('the QR display appears on WaitOtherDeviceConfirmation', (
    tester,
  ) async {
    final bridge = FakeTdlibBridge();
    final controller = await createController(bridge: bridge);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: HarnessScreen(controller: controller)),
    );
    await tester.pump();
    expect(find.text('Scan with Telegram on a second device'), findsNothing);
    bridge.emitAuthUpdate(
      const TdlibAuthUpdate(
        state: 'AuthorizationStateWaitOtherDeviceConfirmation',
        qrLink: 'tg://login?token=test',
      ),
    );
    // One pump is not enough for the stream event to propagate
    // (bridge Stream -> provider -> controller -> rebuild).
    await pumpUntil(tester, () => controller.qrLink != null);
    expect(find.text('Scan with Telegram on a second device'), findsOneWidget);
    // The link itself is never shown as text.
    expect(find.textContaining('tg://'), findsNothing);
  });
}
