import 'dart:async';

import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/telegram/tdlib_method_channel.dart';

/// One outstanding call in the fake, mirroring the real bridge's
/// pending-request tracking (id + method + timedOut flag).
final class _FakePending {
  _FakePending({required this.id, required this.method});

  final int id;
  final String method;
  var timedOut = false;
}

/// Fake [TdlibBridge] for tests. Records calls and lets the test drive
/// auth updates and method outcomes.
///
/// Explicitly a test double (PROJECT_RULES #14): it proves contract
/// behavior, never a real TDLib connection.
final class FakeTdlibBridge implements TdlibBridge {
  FakeTdlibBridge({this.myId = 8934661485});

  final _authUpdates = StreamController<TdlibAuthUpdate>.broadcast();
  final _errors = StreamController<TdlibError>.broadcast();

  int initializeCalls = 0;
  int setTdlibParametersCalls = 0;
  int setPhoneNumberCalls = 0;
  int checkCodeCalls = 0;
  int checkPasswordCalls = 0;
  int requestQrCalls = 0;
  int logOutCalls = 0;
  int closeCalls = 0;
  int disposeCalls = 0;

  int? lastApiId;
  String? lastApiHash;
  String? lastPhoneNumber;
  String? lastCode;

  /// my_id returned by [getMyId]. `0` simulates "no user".
  int myId;

  /// Whether a live TDLib client exists. Set by [initialize], cleared
  /// by [logOut]/[close]/[dispose]. Mirrors the real bridge, where
  /// `setTdlibParameters` on a closed client fails
  /// (`bridge_not_initialized`): the fake enforces the same rule so
  /// the signOut/re-auth lifecycle is testable.
  var clientAlive = false;

  /// Test hook: invoked synchronously inside [setTdlibParameters],
  /// so a test can drive the Ready update at the right moment.
  void Function()? onSetTdlibParameters;

  /// Test hook: invoked synchronously inside [logOut], so a test can
  /// drive the Closed update while signOut is awaiting logOut.
  void Function()? onLogOut;

  /// When set, the next call to the named method throws this error.
  ProviderError? failNextInitialize;
  ProviderError? failNextSetTdlibParameters;
  ProviderError? failNextGetMyId;
  ProviderError? failNextClose;
  ProviderError? failNextLogOut;

  /// When false, [dispose] does not close the streams, so a test can
  /// emit an update after the provider disposed (to prove the provider
  /// ignores it). Default true (matches the real bridge).
  var closeStreamsOnDispose = true;

  var _nextRequestId = 0;
  final Map<int, _FakePending> _pending = {};

  /// Hung calls, keyed by method: the next call to the method waits
  /// for the test to resolve the completer ([resolveHungCall]).
  final Map<String, Completer<void>> _hung = {};

  /// Hung calls that have started (keyed by method), so the test can
  /// resolve them after they are pending.
  final Map<String, Completer<void>> _hungActive = {};

  /// Pending entries of hung calls (keyed by method), so the test can
  /// mark them unresolved ([timeoutHungCall]).
  final Map<String, _FakePending> _hungPending = {};

  @override
  bool hasPendingRequest(String method) =>
      _pending.values.any((r) => r.method == method);

  @override
  bool isRequestUnresolved(String method) =>
      _pending.values.any((r) => r.method == method && r.timedOut);

  /// Makes the next call to [method] hang until the test resolves it
  /// with [resolveHungCall] (simulating a native request whose reply
  /// has not arrived yet).
  void hangNextCall(String method) {
    _hung[method] = Completer<void>();
  }

  /// Marks the hung call for [method] as timed out (simulating the
  /// Dart-side timeout firing while the native request is still
  /// outstanding). The entry stays until [resolveHungCall].
  void timeoutHungCall(String method) {
    final pending = _hungPending[method];
    if (pending != null) pending.timedOut = true;
  }

  /// Completes the hung call for [method] (simulating the late native
  /// reply). With [error], the call completes with that error.
  void resolveHungCall(String method, {Object? error}) {
    final hung = _hungActive[method];
    if (hung != null && !hung.isCompleted) {
      if (error != null) {
        hung.completeError(error);
      } else {
        hung.complete();
      }
    }
  }

  /// Registers a pending request for [method] and, if the test hung
  /// this method ([hangNextCall]), waits for the test to resolve it.
  /// The entry is removed when the call completes, so
  /// [hasPendingRequest] / [isRequestUnresolved] mirror the real
  /// bridge's tracking.
  Future<void> _trackCall(String method) async {
    final id = _nextRequestId++;
    final pending = _FakePending(id: id, method: method);
    _pending[id] = pending;
    try {
      final hung = _hung.remove(method);
      if (hung != null) {
        _hungPending[method] = pending;
        _hungActive[method] = hung;
        try {
          await hung.future;
        } finally {
          _hungPending.remove(method);
          _hungActive.remove(method);
        }
      }
    } finally {
      _pending.remove(id);
    }
  }

  @override
  Stream<TdlibAuthUpdate> get authUpdates => _authUpdates.stream;

  @override
  Stream<TdlibError> get errors => _errors.stream;

  /// Drives an auth update into the provider (as the native side would).
  void emitAuthUpdate(TdlibAuthUpdate update) => _authUpdates.add(update);

  /// Drives a Ready update into the provider.
  void emitReady() =>
      emitAuthUpdate(const TdlibAuthUpdate(state: 'AuthorizationStateReady'));

  /// Drives an unsolicited TDLib error into the provider.
  void emitError(TdlibError error) => _errors.add(error);

  @override
  Future<void> initialize({
    required String databaseDirectory,
    required String filesDirectory,
  }) async {
    initializeCalls++;
    final failure = failNextInitialize;
    failNextInitialize = null;
    if (failure != null) throw failure;
    clientAlive = true;
  }

  @override
  Future<void> setTdlibParameters({
    required int apiId,
    required String apiHash,
    required String databaseDirectory,
    required String filesDirectory,
    required String applicationVersion,
  }) async {
    setTdlibParametersCalls++;
    lastApiId = apiId;
    lastApiHash = apiHash;
    final failure = failNextSetTdlibParameters;
    failNextSetTdlibParameters = null;
    if (failure != null) throw failure;
    // The real bridge rejects calls on a closed client
    // (`bridge_not_initialized`); enforce the same here so a test
    // that calls setTdlibParameters after logOut without an
    // intervening initialize fails the way the real one would.
    if (!clientAlive) {
      throw const ProviderNotInitialized('TDLib client is closed.');
    }
    onSetTdlibParameters?.call();
    await _trackCall(TdlibBridge.setTdlibParametersMethod);
  }

  @override
  Future<void> setAuthenticationPhoneNumber(String phoneNumber) async {
    setPhoneNumberCalls++;
    lastPhoneNumber = phoneNumber;
    await _trackCall(TdlibBridge.setAuthenticationPhoneNumberMethod);
  }

  @override
  Future<void> checkAuthenticationCode(String code) async {
    checkCodeCalls++;
    lastCode = code;
    await _trackCall(TdlibBridge.checkAuthenticationCodeMethod);
  }

  @override
  Future<void> checkAuthenticationPassword(String password) async {
    checkPasswordCalls++;
    await _trackCall(TdlibBridge.checkAuthenticationPasswordMethod);
  }

  @override
  Future<void> requestQrCodeAuthentication() async {
    requestQrCalls++;
    await _trackCall(TdlibBridge.requestQrCodeAuthenticationMethod);
  }

  @override
  Future<String> getOptionVersion() async => '1.8.67';

  @override
  Future<int> getMyId() async {
    final failure = failNextGetMyId;
    failNextGetMyId = null;
    if (failure != null) throw failure;
    await _trackCall(TdlibBridge.getMyIdMethod);
    return myId;
  }

  @override
  Future<void> logOut() async {
    logOutCalls++;
    final failure = failNextLogOut;
    failNextLogOut = null;
    if (failure != null) throw failure;
    onLogOut?.call();
    // The client is closed by LogOut; the native side then emits
    // LoggingOut -> Closed. The test drives the Closed update itself
    // (emitAuthUpdate) so it can control the timing.
    clientAlive = false;
    await _trackCall(TdlibBridge.logOutMethod);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    final failure = failNextClose;
    failNextClose = null;
    if (failure != null) throw failure;
    clientAlive = false;
    // Mirror reality: the native side emits Closed after Close.
    emitAuthUpdate(const TdlibAuthUpdate(state: 'AuthorizationStateClosed'));
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    clientAlive = false;
    if (closeStreamsOnDispose) {
      await _authUpdates.close();
      await _errors.close();
    }
  }
}
