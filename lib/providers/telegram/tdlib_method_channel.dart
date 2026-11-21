import 'dart:async';

import 'package:flutter/services.dart';

import '../provider_error.dart';
import 'telegram_errors.dart';

/// One authorization-state notification from the native TDLib bridge.
///
/// [state] is the TDLib state class simple name, e.g.
/// `'AuthorizationStateWaitCode'`. Payload fields are present only for
/// the states that carry them (mirroring the spike's reporting).
final class TdlibAuthUpdate {
  const TdlibAuthUpdate({
    required this.state,
    this.codeInfo,
    this.passwordHint,
    this.qrLink,
    this.emailAddressPattern,
    this.emailCodeLength,
  });

  final String state;

  /// WaitCode payload: `{type: {name, length}, nextType: {name, length},
  /// timeoutSeconds}`. No phone number, no verifier data.
  final Map<String, Object?>? codeInfo;

  /// WaitPassword payload: the password hint (display only).
  final String? passwordHint;

  /// WaitOtherDeviceConfirmation payload: the confirmation link.
  /// A login token — in-memory only, never logged or persisted.
  final String? qrLink;

  /// WaitEmailCode payload: masked email pattern.
  final String? emailAddressPattern;

  /// WaitEmailCode payload: expected code length.
  final int? emailCodeLength;

  factory TdlibAuthUpdate.fromMap(Map<Object?, Object?> map) {
    Map<String, Object?>? codeInfo;
    final rawCodeInfo = map['codeInfo'];
    if (rawCodeInfo is Map) {
      codeInfo = Map<String, Object?>.from(rawCodeInfo);
    }
    return TdlibAuthUpdate(
      state: map['state'] as String? ?? '',
      codeInfo: codeInfo,
      passwordHint: map['passwordHint'] as String?,
      qrLink: map['qrLink'] as String?,
      emailAddressPattern: map['emailAddressPattern'] as String?,
      emailCodeLength: map['emailCodeLength'] as int?,
    );
  }
}

/// A TDLib error not tied to a method call (client error handler).
final class TdlibError {
  const TdlibError({required this.code, required this.message});

  /// TDLib numeric error code (e.g. 400).
  final int code;

  /// TDLib error message (never contains secrets).
  final String message;
}

/// Abstraction over the native TDLib bridge (MethodChannel).
///
/// The real implementation talks to Kotlin; tests inject a fake.
/// Method calls that TDLib rejects surface as the mapped
/// [ProviderError] (see [_mapPlatformException]).
abstract interface class TdlibBridge {
  /// MethodChannel method names, defined once so the provider's
  /// pending-request checks and the bridge's invocations can never
  /// disagree about a name.
  static const String initializeMethod = 'initialize';
  static const String setTdlibParametersMethod = 'setTdlibParameters';
  static const String setAuthenticationPhoneNumberMethod =
      'setAuthenticationPhoneNumber';
  static const String checkAuthenticationCodeMethod = 'checkAuthenticationCode';
  static const String checkAuthenticationPasswordMethod =
      'checkAuthenticationPassword';
  static const String requestQrCodeAuthenticationMethod =
      'requestQrCodeAuthentication';
  static const String getOptionVersionMethod = 'getOptionVersion';
  static const String getMyIdMethod = 'getMyId';
  static const String logOutMethod = 'logOut';
  static const String closeMethod = 'close';
  static const String disposeMethod = 'dispose';
  static const String getNoBackupFilesDirectoryMethod =
      'getNoBackupFilesDirectory';

  /// Authorization-state notifications from the native client.
  Stream<TdlibAuthUpdate> get authUpdates;

  /// Unsolicited TDLib errors (client error handler).
  Stream<TdlibError> get errors;

  /// Whether a request for [method] is currently outstanding — still
  /// executing, or timed out but not yet answered. The provider
  /// refuses a duplicate send while this is true.
  bool hasPendingRequest(String method);

  /// Whether a request for [method] timed out and its native result
  /// has not arrived yet. Diagnostics only; [hasPendingRequest]
  /// covers both the in-flight and the unresolved case.
  bool isRequestUnresolved(String method);

  /// Loads tdjni and creates the TDLib client. The client starts in
  /// `AuthorizationStateWaitTdlibParameters`.
  ///
  /// Fail-fast: refuses (`bridge_previous_client_open`) when a
  /// previous client is still open (not confirmed closed). The caller
  /// must wait for the `Closed` state before re-initializing.
  Future<void> initialize({
    required String databaseDirectory,
    required String filesDirectory,
  });

  /// Sends `SetTdlibParameters` (api id/hash, directories, version).
  /// Times out after 10s ([ProviderRequestUnresolved]) if TDLib does
  /// not answer. [databaseEncryptionKey] is the 32-byte key that
  /// encrypts the TDLib database; it is bytes end-to-end and is never
  /// logged. The same key must be supplied on every launch.
  Future<void> setTdlibParameters({
    required int apiId,
    required String apiHash,
    required String databaseDirectory,
    required String filesDirectory,
    required String applicationVersion,
    required Uint8List databaseEncryptionKey,
  });

  /// Returns the Android no-backup files directory
  /// (`Context.getNoBackupFilesDir()`), which the OS excludes from
  /// Auto Backup. The TDLib database lives under it so a backup can
  /// never restore a database without its (Keystore-bound) key.
  Future<String> getNoBackupFilesDirectory();

  /// Sends `SetAuthenticationPhoneNumber`.
  Future<void> setAuthenticationPhoneNumber(String phoneNumber);

  /// Sends `CheckAuthenticationCode`.
  Future<void> checkAuthenticationCode(String code);

  /// Sends `CheckAuthenticationPassword`.
  Future<void> checkAuthenticationPassword(String password);

  /// Sends `RequestQrCodeAuthentication`.
  Future<void> requestQrCodeAuthentication();

  /// Synchronous `GetOption("version")` via `Client.execute`.
  Future<String> getOptionVersion();

  /// Asynchronous `GetOption("my_id")` (5s timeout). Only meaningful
  /// after authorization; pre-auth it is not available (Task 03).
  Future<int> getMyId();

  /// Sends `LogOut` (wipes the session, per user choice). Times out
  /// after 30s ([ProviderRequestUnresolved]) if TDLib does not
  /// answer; a timeout does not prove the logout did not happen (the
  /// native logout may still complete and the Closed state may still
  /// arrive on [authUpdates]).
  Future<void> logOut();

  /// Sends `Close` and waits for the `Closed` state (up to 8s).
  /// A second client must never be created on the same database
  /// before the first one is confirmed closed (Task 03/04).
  Future<void> close();

  /// Releases the bridge. Idempotent; safe to call at any time.
  Future<void> dispose();
}

/// One outstanding native call. A timeout never removes the entry:
/// it only sets [timedOut]. The entry is removed only when the native
/// reply eventually arrives (on time or late), so a timeout is never
/// mistaken for a cancellation and an older request's late result
/// never drops a newer request's entry. A `Set<String>` would be
/// insufficient: two requests of the same method can be outstanding
/// at once (a retry after a timeout, or two concurrent step calls),
/// and clearing the method name on the first late result would wrongly
/// allow a third request while the second is still pending.
final class _PendingRequest {
  _PendingRequest({required this.id, required this.method});

  final int id;
  final String method;

  /// True once the Dart-side timeout fired. The native request is
  /// still outstanding; only its reply clears the entry.
  var timedOut = false;
}

/// MethodChannel implementation of [TdlibBridge].
///
/// Channel `telemanager.tdlib`. Native callbacks arrive as method
/// calls: `onAuthorizationState` and `onError`.
final class MethodChannelTdlibBridge implements TdlibBridge {
  /// Creates the bridge on [channel] (or the `telemanager.tdlib`
  /// channel). [timeoutOverride] replaces every per-method Dart-side
  /// timeout when set; it exists only so tests can trigger the
  /// unresolved-request path quickly. Production code never sets it.
  MethodChannelTdlibBridge([MethodChannel? channel, this.timeoutOverride])
    : _channel = channel ?? const MethodChannel('telemanager.tdlib') {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  /// Replaces every per-method Dart-side timeout when set. Test-only.
  final Duration? timeoutOverride;

  final MethodChannel _channel;
  final _authUpdates = StreamController<TdlibAuthUpdate>.broadcast();
  final _errors = StreamController<TdlibError>.broadcast();
  var _disposed = false;

  var _nextRequestId = 0;
  final Map<int, _PendingRequest> _pendingRequests = {};

  @override
  bool hasPendingRequest(String method) =>
      _pendingRequests.values.any((r) => r.method == method);

  @override
  bool isRequestUnresolved(String method) =>
      _pendingRequests.values.any((r) => r.method == method && r.timedOut);

  @override
  Stream<TdlibAuthUpdate> get authUpdates => _authUpdates.stream;

  @override
  Stream<TdlibError> get errors => _errors.stream;

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onAuthorizationState':
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        _authUpdates.add(TdlibAuthUpdate.fromMap(args));
      case 'onError':
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        _errors.add(
          TdlibError(
            code: args['code'] as int? ?? 0,
            message: args['message'] as String? ?? '',
          ),
        );
    }
  }

  @override
  Future<void> initialize({
    required String databaseDirectory,
    required String filesDirectory,
  }) async {
    await _invoke(TdlibBridge.initializeMethod, {
      'databaseDirectory': databaseDirectory,
      'filesDirectory': filesDirectory,
    });
  }

  @override
  Future<void> setTdlibParameters({
    required int apiId,
    required String apiHash,
    required String databaseDirectory,
    required String filesDirectory,
    required String applicationVersion,
    required Uint8List databaseEncryptionKey,
  }) async {
    await _invoke(TdlibBridge.setTdlibParametersMethod, {
      'apiId': apiId,
      'apiHash': apiHash,
      'databaseDirectory': databaseDirectory,
      'filesDirectory': filesDirectory,
      'applicationVersion': applicationVersion,
      // Sent as binary (Uint8List), never as a string, and never logged.
      'databaseEncryptionKey': databaseEncryptionKey,
    }, timeout: const Duration(seconds: 10));
  }

  @override
  Future<String> getNoBackupFilesDirectory() async {
    final result = await _invoke(
      TdlibBridge.getNoBackupFilesDirectoryMethod,
      {},
    );
    return (result as Map)['path'] as String;
  }

  /// Test-only (debug builds only): arms a reply delay for a TDLib
  /// method. The request is still sent immediately; only the delivery
  /// of its result to Dart is delayed by [delayMs]. In a release build
  /// the native side reports `notImplemented`. The Harness (kDebugMode)
  /// is the only caller. Not part of [TdlibBridge] (test-only surface).
  Future<void> setTestReplyDelay(String method, int delayMs) async {
    await _invoke('setTestReplyDelay', {'method': method, 'delayMs': delayMs});
  }

  /// Test-only (debug builds only): clears all armed reply delays.
  /// Not part of [TdlibBridge] (test-only surface).
  Future<void> clearTestReplyDelays() async {
    await _invoke('clearTestReplyDelays', {});
  }

  /// Test-only (debug builds only): how many times each delayable
  /// TDLib method was sent to the native client. Used by D1 to prove
  /// no second `setTdlibParameters` was sent. Not part of [TdlibBridge]
  /// (test-only surface).
  Future<Map<String, int>> getTestSendCounts() async {
    final result = await _invoke('getTestSendCounts', {});
    final map = result as Map;
    return map.map(
      (key, value) => MapEntry(key as String, (value as num).toInt()),
    );
  }

  @override
  Future<void> setAuthenticationPhoneNumber(String phoneNumber) async {
    await _invoke(TdlibBridge.setAuthenticationPhoneNumberMethod, {
      'phoneNumber': phoneNumber,
    }, timeout: const Duration(seconds: 30));
  }

  @override
  Future<void> checkAuthenticationCode(String code) async {
    await _invoke(TdlibBridge.checkAuthenticationCodeMethod, {
      'code': code,
    }, timeout: const Duration(seconds: 30));
  }

  @override
  Future<void> checkAuthenticationPassword(String password) async {
    await _invoke(TdlibBridge.checkAuthenticationPasswordMethod, {
      'password': password,
    }, timeout: const Duration(seconds: 30));
  }

  @override
  Future<void> requestQrCodeAuthentication() async {
    await _invoke(
      TdlibBridge.requestQrCodeAuthenticationMethod,
      {},
      timeout: const Duration(seconds: 30),
    );
  }

  @override
  Future<String> getOptionVersion() async {
    final result = await _invoke(TdlibBridge.getOptionVersionMethod, {});
    return (result as Map)['value'] as String;
  }

  @override
  Future<int> getMyId() async {
    final result = await _invoke(TdlibBridge.getMyIdMethod, {});
    return (result as Map)['myId'] as int;
  }

  @override
  Future<void> logOut() async {
    await _invoke(
      TdlibBridge.logOutMethod,
      {},
      timeout: const Duration(seconds: 30),
    );
  }

  @override
  Future<void> close() async {
    await _invoke(TdlibBridge.closeMethod, {});
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel.invokeMethod(TdlibBridge.disposeMethod, {});
    } on PlatformException {
      // Best-effort: dispose must never throw.
    } on MissingPluginException {
      // No native side (e.g. unit tests without a host): ignore.
    }
    await _authUpdates.close();
    await _errors.close();
  }

  /// Invokes a native method. When [timeout] is given, a technical
  /// request that TDLib never answers fails with
  /// [ProviderRequestUnresolved] instead of hanging forever — the
  /// native request is still outstanding and may still complete, so
  /// the timeout is never treated as a cancellation. The user-wait
  /// that follows a request (for phone/code/QR input) is not a method
  /// call and has no timeout.
  ///
  /// Every call is tracked by a unique request id (see
  /// [_PendingRequest]): the entry is removed only when the native
  /// reply arrives (on time or late). A timeout only marks it
  /// unresolved. The provider reads the tracking through
  /// [hasPendingRequest] / [isRequestUnresolved] and refuses a
  /// duplicate send while a previous request is outstanding.
  Future<Object?> _invoke(
    String method,
    Map<String, Object?> args, {
    Duration? timeout,
  }) async {
    // Register synchronously, before the first await, so the
    // registration is atomic in Dart's single-threaded event loop:
    // no second call can slip in between a duplicate check and
    // this insert.
    final id = _nextRequestId++;
    final pending = _PendingRequest(id: id, method: method);
    _pendingRequests[id] = pending;
    try {
      final future = _channel.invokeMethod(method, args);
      // Clear the entry when the native reply eventually arrives, on
      // time or late, with a value or an error. Never on timeout: the
      // request is still outstanding until the native side answers.
      // `then` with both handlers (not `whenComplete`) so the derived
      // future completes normally in both cases and never surfaces
      // an unhandled async error.
      unawaited(
        future.then(
          (_) => _pendingRequests.remove(id),
          onError: (_, _) => _pendingRequests.remove(id),
        ),
      );
      final effectiveTimeout = timeoutOverride ?? timeout;
      if (effectiveTimeout == null) return await future;
      return await future.timeout(
        effectiveTimeout,
        onTimeout: () {
          pending.timedOut = true;
          throw ProviderRequestUnresolved(
            method,
            'Timed out waiting for TDLib ($method); the request is '
            'still unresolved.',
          );
        },
      );
    } on ProviderError {
      rethrow;
    } on PlatformException catch (e) {
      throw _mapPlatformException(e, method);
    } on MissingPluginException {
      throw const ProviderUnknown(
        'missing_plugin',
        'TDLib bridge is not registered on this platform.',
      );
    }
  }
}

/// Maps a [PlatformException] from the native bridge onto
/// [ProviderError]. The native side reports TDLib errors with the
/// numeric TDLib code as the exception code, so they route through
/// [mapTdlibError]; bridge-internal errors use `bridge_*` codes.
ProviderError _mapPlatformException(PlatformException e, String method) {
  final tdlibCode = int.tryParse(e.code);
  if (tdlibCode != null) {
    return mapTdlibError(tdlibCode, e.message ?? '');
  }
  switch (e.code) {
    case 'bridge_timeout':
      // The native operation did not answer in time (getMyId's 5s
      // latch, close's 8s latch). Its outcome is unknown, not a
      // confirmed network failure — and the method name is kept so
      // the caller knows which request is unresolved.
      return ProviderRequestUnresolved(
        method,
        e.message ?? 'Timed out waiting for TDLib.',
      );
    case 'bridge_not_initialized':
      return const ProviderNotInitialized('TDLib bridge is not initialized.');
    case 'bridge_disposed':
      return const ProviderUnknown(
        'bridge_disposed',
        'TDLib bridge is disposed.',
      );
    default:
      return ProviderUnknown(e.code, e.message ?? 'Unknown bridge error.');
  }
}
