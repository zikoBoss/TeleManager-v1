import 'package:telemanager/features/developer/harness/harness_test_hooks.dart';

/// In-memory [HarnessTestHooks] for tests.
final class FakeHarnessTestHooks implements HarnessTestHooks {
  /// Armed delays (method -> delayMs).
  final Map<String, int> delays = {};

  /// Send counts returned by [getTestSendCounts]. Tests set this.
  Map<String, int> sendCounts = {};

  @override
  Future<void> setTestReplyDelay(String method, int delayMs) async {
    if (delayMs == 0) {
      delays.remove(method);
    } else {
      delays[method] = delayMs;
    }
  }

  @override
  Future<void> clearTestReplyDelays() async {
    delays.clear();
  }

  @override
  Future<Map<String, int>> getTestSendCounts() async => Map.of(sendCounts);
}
