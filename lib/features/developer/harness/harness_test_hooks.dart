import '../../../providers/telegram/tdlib_method_channel.dart';

/// Test-only bridge hooks used by the Harness (debug builds only).
///
/// These are separate from [TdlibBridge] so the production interface
/// stays clean: the delay hook and the send counter exist only for the
/// temporary Harness and are removed with it. The HarnessController
/// depends on this interface, so it is testable with a fake.
abstract interface class HarnessTestHooks {
  /// Arms a reply delay for a delayable TDLib method
  /// (`setTdlibParameters` or `logOut`). A delay of 0 disarms it.
  Future<void> setTestReplyDelay(String method, int delayMs);

  /// Clears all armed reply delays.
  Future<void> clearTestReplyDelays();

  /// How many times each delayable TDLib method was sent.
  Future<Map<String, int>> getTestSendCounts();
}

/// Real [HarnessTestHooks] backed by [MethodChannelTdlibBridge].
/// The native side enforces the debug-only gate (notImplemented in
/// release builds).
final class MethodChannelHarnessTestHooks implements HarnessTestHooks {
  MethodChannelHarnessTestHooks(this._bridge);

  final MethodChannelTdlibBridge _bridge;

  @override
  Future<void> setTestReplyDelay(String method, int delayMs) =>
      _bridge.setTestReplyDelay(method, delayMs);

  @override
  Future<void> clearTestReplyDelays() => _bridge.clearTestReplyDelays();

  @override
  Future<Map<String, int>> getTestSendCounts() => _bridge.getTestSendCounts();
}
