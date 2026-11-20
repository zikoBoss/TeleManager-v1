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
  /// Authorization-state notifications from the native client.
  Stream<TdlibAuthUpdate> get authUpdates;

  /// Unsolicited TDLib errors (client error handler).
  Stream<TdlibError> get errors;

  /// Loads tdjni and creates the TDLib client. The client starts in
  /// `AuthorizationStateWaitTdlibParameters`.
  Future<void> initialize({
    required String databaseDirectory,
    required String filesDirectory,
  });

  /// Sends `SetTdlibParameters` (api id/hash, directories, version).
  Future<void> setTdlibParameters({
    required int apiId,
    required String apiHash,
    required String databaseDirectory,
    required String filesDirectory,
    required String applicationVersion,
  });

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

  /// Sends `LogOut` (wipes the session, per user choice).
  Future<void> logOut();

  /// Sends `Close` and waits for the `Closed` state (up to 8s).
  /// A second client must never be created on the same database
  /// before the first one is confirmed closed (Task 03/04).
  Future<void> close();

  /// Releases the bridge. Idempotent; safe to call at any time.
  Future<void> dispose();
}

/// MethodChannel implementation of [TdlibBridge].
///
/// Channel `telemanager.tdlib`. Native callbacks arrive as method
/// calls: `onAuthorizationState` and `onError`.
final class MethodChannelTdlibBridge implements TdlibBridge {
  MethodChannelTdlibBridge([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel('telemanager.tdlib') {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  final MethodChannel _channel;
  final _authUpdates = StreamController<TdlibAuthUpdate>.broadcast();
  final _errors = StreamController<TdlibError>.broadcast();
  var _disposed = false;

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
    await _invoke('initialize', {
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
  }) async {
    await _invoke('setTdlibParameters', {
      'apiId': apiId,
      'apiHash': apiHash,
      'databaseDirectory': databaseDirectory,
      'filesDirectory': filesDirectory,
      'applicationVersion': applicationVersion,
    });
  }

  @override
  Future<void> setAuthenticationPhoneNumber(String phoneNumber) async {
    await _invoke('setAuthenticationPhoneNumber', {
      'phoneNumber': phoneNumber,
    });
  }

  @override
  Future<void> checkAuthenticationCode(String code) async {
    await _invoke('checkAuthenticationCode', {'code': code});
  }

  @override
  Future<void> checkAuthenticationPassword(String password) async {
    await _invoke('checkAuthenticationPassword', {'password': password});
  }

  @override
  Future<void> requestQrCodeAuthentication() async {
    await _invoke('requestQrCodeAuthentication', {});
  }

  @override
  Future<String> getOptionVersion() async {
    final result = await _invoke('getOptionVersion', {});
    return (result as Map)['value'] as String;
  }

  @override
  Future<int> getMyId() async {
    final result = await _invoke('getMyId', {});
    return (result as Map)['myId'] as int;
  }

  @override
  Future<void> logOut() async {
    await _invoke('logOut', {});
  }

  @override
  Future<void> close() async {
    await _invoke('close', {});
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel.invokeMethod('dispose', {});
    } on PlatformException {
      // Best-effort: dispose must never throw.
    } on MissingPluginException {
      // No native side (e.g. unit tests without a host): ignore.
    }
    await _authUpdates.close();
    await _errors.close();
  }

  Future<Object?> _invoke(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod(method, args);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
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
ProviderError _mapPlatformException(PlatformException e) {
  final tdlibCode = int.tryParse(e.code);
  if (tdlibCode != null) {
    return mapTdlibError(tdlibCode, e.message ?? '');
  }
  switch (e.code) {
    case 'bridge_timeout':
      return ProviderNetwork(e.message ?? 'Timed out waiting for TDLib.');
    case 'bridge_not_initialized':
      return const ProviderNotInitialized(
        'TDLib bridge is not initialized.',
      );
    case 'bridge_disposed':
      return const ProviderUnknown(
        'bridge_disposed',
        'TDLib bridge is disposed.',
      );
    default:
      return ProviderUnknown(e.code, e.message ?? 'Unknown bridge error.');
  }
}
