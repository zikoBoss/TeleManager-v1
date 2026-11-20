import 'dart:async';

import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/telegram/tdlib_method_channel.dart';

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

  /// Test hook: invoked synchronously inside [setTdlibParameters],
  /// so a test can drive the Ready update at the right moment.
  void Function()? onSetTdlibParameters;

  /// When set, the next call to the named method throws this error.
  ProviderError? failNextInitialize;
  ProviderError? failNextSetTdlibParameters;
  ProviderError? failNextGetMyId;
  ProviderError? failNextClose;

  @override
  Stream<TdlibAuthUpdate> get authUpdates => _authUpdates.stream;

  @override
  Stream<TdlibError> get errors => _errors.stream;

  /// Drives an auth update into the provider (as the native side would).
  void emitAuthUpdate(TdlibAuthUpdate update) => _authUpdates.add(update);

  /// Drives a Ready update into the provider.
  void emitReady() => emitAuthUpdate(
        const TdlibAuthUpdate(state: 'AuthorizationStateReady'),
      );

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
    onSetTdlibParameters?.call();
  }

  @override
  Future<void> setAuthenticationPhoneNumber(String phoneNumber) async {
    setPhoneNumberCalls++;
    lastPhoneNumber = phoneNumber;
  }

  @override
  Future<void> checkAuthenticationCode(String code) async {
    checkCodeCalls++;
    lastCode = code;
  }

  @override
  Future<void> checkAuthenticationPassword(String password) async {
    checkPasswordCalls++;
  }

  @override
  Future<void> requestQrCodeAuthentication() async {
    requestQrCalls++;
  }

  @override
  Future<String> getOptionVersion() async => '1.8.67';

  @override
  Future<int> getMyId() async {
    final failure = failNextGetMyId;
    failNextGetMyId = null;
    if (failure != null) throw failure;
    return myId;
  }

  @override
  Future<void> logOut() async {
    logOutCalls++;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    final failure = failNextClose;
    failNextClose = null;
    if (failure != null) throw failure;
    // Mirror reality: the native side emits Closed after Close.
    emitAuthUpdate(
      const TdlibAuthUpdate(state: 'AuthorizationStateClosed'),
    );
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _authUpdates.close();
    await _errors.close();
  }
}
