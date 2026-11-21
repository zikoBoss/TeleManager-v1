// ignore_for_file: prefer_initializing_formals
// The constructor's parameters are public named arguments used by callers
// outside this library, while the fields are intentionally private, so
// initializing formals cannot apply here.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../providers/auth_state.dart';
import '../../../providers/provider_error.dart';
import '../../../providers/telegram/tdlib_database_key_store.dart';
import '../../../providers/telegram/tdlib_method_channel.dart';
import '../../../providers/telegram/telegram_auth_steps.dart';
import '../../../providers/telegram/telegram_credentials_store.dart';
import '../../../providers/telegram/telegram_provider.dart';
import 'harness_event_log.dart';
import 'harness_sanitizer.dart';
import 'harness_test_hooks.dart';

/// Temporary developer Test Harness controller (Task 05, D1–D5).
///
/// Owns a real [TelegramProvider] (real bridge, real TDLib — no fakes
/// on the device) and drives the Harness actions: authenticate, sign
/// out, dispose, create a new provider, reset the test session, and
/// the debug-only reply-delay / send-count diagnostics.
///
/// Temporary: this whole feature (controller, screen, delay hook,
/// send counter, entry point) is removed after D1–D5. The permanent
/// protections (database encryption key, no-backup path) live in the
/// provider/bridge, not here.
///
/// Never logs secrets: the event log contains state names, error
/// codes, timings, and action results only. `my_id` is shown on the
/// screen (the user needs it to verify) but is never written to the
/// log; the log records only whether it matches the expected test
/// account. The QR link is exposed to the screen for rendering and is
/// never logged.
final class HarnessController extends ChangeNotifier {
  HarnessController({
    required TdlibBridge bridge,
    required HarnessTestHooks testHooks,
    required TelegramCredentialsStore credentialsStore,
    required TdlibDatabaseKeyStore databaseKeyStore,
    required String databaseDirectory,
    required String filesDirectory,
  }) : _bridge = bridge,
       _testHooks = testHooks,
       _credentialsStore = credentialsStore,
       _databaseKeyStore = databaseKeyStore,
       _databaseDirectory = databaseDirectory,
       _filesDirectory = filesDirectory;

  /// Builds a real controller (real bridge, real stores, no-backup
  /// directories) and initializes its provider.
  static Future<HarnessController> create() async {
    final bridge = MethodChannelTdlibBridge();
    final noBackupDir = await bridge.getNoBackupFilesDirectory();
    final controller = HarnessController(
      bridge: bridge,
      testHooks: MethodChannelHarnessTestHooks(bridge),
      credentialsStore: SecureTelegramCredentialsStore(),
      databaseKeyStore: SecureTdlibDatabaseKeyStore(),
      databaseDirectory: '$noBackupDir/tdlib',
      filesDirectory: '$noBackupDir/tdlib/files',
    );
    await controller.initialize();
    return controller;
  }

  final TdlibBridge _bridge;
  final HarnessTestHooks _testHooks;
  final TelegramCredentialsStore _credentialsStore;
  final TdlibDatabaseKeyStore _databaseKeyStore;
  final String _databaseDirectory;
  final String _filesDirectory;

  TelegramProvider? _provider;
  StreamSubscription<AuthState>? _authSub;

  /// The sanitized in-memory event log.
  final HarnessEventLog eventLog = HarnessEventLog();

  AuthState _authState = const AuthUnauthenticated();
  ProviderError? _lastError;
  String? _myId;
  String? _qrLink;
  var _busy = false;
  var _providerInitialized = false;
  var _credentialsSaved = false;
  String _keyStatus = 'unknown';
  Map<String, int> _sendCounts = {};
  var _pendingSetTdlibParameters = false;
  var _unresolvedSetTdlibParameters = false;
  var _pendingLogOut = false;
  var _unresolvedLogOut = false;
  String? _lastActionResult;

  AuthState get authState => _authState;
  ProviderError? get lastError => _lastError;

  /// The authenticated account id (shown on the screen only, never
  /// logged). `null` when not authenticated.
  String? get myId => _myId;

  /// Whether the authenticated account is the expected test account
  /// (`8934661485`). The log records this yes/no, never the id itself.
  bool get myIdMatchesExpected => _myId == '8934661485';

  /// The QR login link, when the current step is
  /// WaitOtherDeviceConfirmation. Exposed to the screen for rendering
  /// only; never logged, never put in the event log or reports.
  String? get qrLink => _qrLink;

  bool get busy => _busy;
  bool get providerInitialized => _providerInitialized;
  bool get credentialsSaved => _credentialsSaved;

  /// Database key status: `present`, `missing`, `corrupt`,
  /// `unreadable`, or `unknown`. Never the key itself.
  String get keyStatus => _keyStatus;

  Map<String, int> get sendCounts => Map.unmodifiable(_sendCounts);
  bool get pendingSetTdlibParameters => _pendingSetTdlibParameters;
  bool get unresolvedSetTdlibParameters => _unresolvedSetTdlibParameters;
  bool get pendingLogOut => _pendingLogOut;
  bool get unresolvedLogOut => _unresolvedLogOut;

  /// Result of the last action (human-readable, sanitized), or null.
  String? get lastActionResult => _lastActionResult;

  String get databaseDirectoryLabel => 'no-backup/tdlib';

  /// Creates the provider and initializes it. Called once by
  /// [create]; [createNewProvider] does the same after a dispose.
  Future<void> initialize() async {
    if (_provider != null) return;
    _setBusy(true);
    try {
      await _createAndInitializeProvider();
      await refreshCredentialsStatus();
      await refreshKeyStatus();
      await refreshPending();
      _log('harness initialized');
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _createAndInitializeProvider() async {
    final provider = TelegramProvider(
      bridge: _bridge,
      credentialsStore: _credentialsStore,
      databaseKeyStore: _databaseKeyStore,
      databaseDirectory: _databaseDirectory,
      filesDirectory: _filesDirectory,
    );
    _provider = provider;
    _authSub = provider.authStates.listen(_onAuthState);
    await provider.initialize();
    _providerInitialized = true;
    _authState = provider.currentAuthState;
  }

  /// Creates a new provider after a dispose (D5 cycles, D2 after a
  /// reset). Refuses when a provider already exists.
  Future<void> createNewProvider() async {
    if (_provider != null) {
      _setActionResult('a provider already exists; dispose it first');
      return;
    }
    _setBusy(true);
    try {
      await _createAndInitializeProvider();
      await refreshKeyStatus();
      await refreshPending();
      _setActionResult('new provider created and initialized');
      _log('new provider created');
    } catch (e) {
      _setActionResult('create provider failed: ${_errorLabel(e)}');
      _log('create provider failed: ${_errorLabel(e)}');
    } finally {
      _setBusy(false);
    }
  }

  /// Disposes the current provider (the TDLib client is closed and
  /// confirmed). A new provider must be created explicitly afterwards.
  Future<void> disposeProvider() async {
    final provider = _provider;
    if (provider == null) {
      _setActionResult('no provider to dispose');
      return;
    }
    _setBusy(true);
    try {
      await _authSub?.cancel();
      _authSub = null;
      await provider.dispose();
      _provider = null;
      _providerInitialized = false;
      _authState = const AuthUnauthenticated();
      _myId = null;
      _qrLink = null;
      await refreshPending();
      _setActionResult('provider disposed');
      _log('provider disposed');
    } catch (e) {
      _setActionResult('dispose failed: ${_errorLabel(e)}');
      _log('dispose failed: ${_errorLabel(e)}');
    } finally {
      _setBusy(false);
    }
  }

  /// Authenticates with the stored credentials. The result arrives as
  /// the terminal [AuthState]; intermediate states arrive on the
  /// auth-states stream. A QR step (if any) exposes [qrLink] for the
  /// screen to render.
  Future<void> authenticate() async {
    final provider = _provider;
    if (provider == null || !_providerInitialized) {
      _setActionResult('no initialized provider; create one first');
      return;
    }
    _setBusy(true);
    try {
      final result = await provider.authenticate();
      _setActionResult('authenticate -> ${_stateName(result)}');
      _log('authenticate -> ${_stateName(result)}');
      await refreshPending();
      await refreshSendCounts();
    } catch (e) {
      _setActionResult('authenticate threw: ${_errorLabel(e)}');
      _log('authenticate threw: ${_errorLabel(e)}');
    } finally {
      _setBusy(false);
    }
  }

  /// Signs out. After a successful signOut the provider re-initializes
  /// (per the Task 05 contract) and can authenticate again. After a
  /// logOut timeout the provider is unusable and must be disposed.
  Future<void> signOut() async {
    final provider = _provider;
    if (provider == null || !_providerInitialized) {
      _setActionResult('no initialized provider; create one first');
      return;
    }
    _setBusy(true);
    try {
      await provider.signOut();
      _setActionResult('signOut completed');
      _log('signOut completed');
      await refreshPending();
      await refreshSendCounts();
    } on ProviderError catch (e) {
      _setActionResult('signOut failed: ${e.code}');
      _log('signOut failed: ${e.code}');
    } catch (e) {
      _setActionResult('signOut threw: ${_errorLabel(e)}');
      _log('signOut threw: ${_errorLabel(e)}');
    } finally {
      _setBusy(false);
    }
  }

  /// Explicit test-session reset (D1 exit, before D2). Deletes the
  /// TeleManager TDLib database directory AND clears its encryption
  /// key, together, and verifies both before returning. Credentials
  /// are kept. The Spike is never touched (different package, different
  /// data directory). A new provider must be created explicitly
  /// afterwards ([createNewProvider]).
  ///
  /// Refuses when a request is still pending or unresolved (the D1
  /// late reply must arrive and release the pending entry first).
  /// On any verification failure it reports the failure and does NOT
  /// create a provider.
  Future<void> resetTestSession() async {
    if (_busy) return;
    _setBusy(true);
    try {
      await refreshPending();
      if (_pendingSetTdlibParameters ||
          _unresolvedSetTdlibParameters ||
          _pendingLogOut ||
          _unresolvedLogOut) {
        _setActionResult(
          'reset refused: a request is still pending or unresolved; '
          'wait for the late reply first',
        );
        _log('reset refused: pending request');
        return;
      }
      // Dispose first: the TDLib client must be closed before its
      // database directory is deleted.
      if (_provider != null) {
        await disposeProvider();
      }
      // Delete the database directory and clear its key, together.
      var dirDeleted = false;
      var keyCleared = false;
      try {
        final dir = Directory(_databaseDirectory);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
        dirDeleted = true;
      } catch (e) {
        _log('reset: database delete failed: ${_errorLabel(e)}');
      }
      try {
        await _databaseKeyStore.clearKey();
        keyCleared = true;
      } catch (e) {
        _log('reset: key clear failed: ${_errorLabel(e)}');
      }
      // Verify both before declaring success.
      final dirGone = !(await Directory(_databaseDirectory).exists());
      var keyGone = false;
      try {
        keyGone = await _databaseKeyStore.readKey() == null;
      } catch (_) {
        keyGone = false;
      }
      if (dirDeleted && keyCleared && dirGone && keyGone) {
        _setActionResult(
          'test session reset verified (database deleted, key cleared)',
        );
        _log('test session reset verified');
        await refreshKeyStatus();
      } else {
        _setActionResult(
          'reset verification FAILED '
          '(dir deleted: $dirDeleted, dir gone: $dirGone, '
          'key cleared: $keyCleared, key gone: $keyGone); '
          'no provider created',
        );
        _log('reset verification FAILED');
      }
    } finally {
      _setBusy(false);
    }
  }

  /// Arms a reply delay (debug builds only) for a delayable method.
  /// D1: `setTdlibParameters`, 15000 ms. D3: `logOut`, 35000 ms.
  Future<void> setReplyDelay(String method, int delayMs) async {
    try {
      await _testHooks.setTestReplyDelay(method, delayMs);
      _setActionResult('reply delay armed: $method ${delayMs}ms');
      _log('reply delay armed: $method ${delayMs}ms');
    } catch (e) {
      _setActionResult('set reply delay failed: ${_errorLabel(e)}');
      _log('set reply delay failed: ${_errorLabel(e)}');
    }
  }

  /// Clears all armed reply delays.
  Future<void> clearReplyDelays() async {
    try {
      await _testHooks.clearTestReplyDelays();
      _setActionResult('reply delays cleared');
      _log('reply delays cleared');
    } catch (e) {
      _setActionResult('clear reply delays failed: ${_errorLabel(e)}');
      _log('clear reply delays failed: ${_errorLabel(e)}');
    }
  }

  /// Saves the API credentials (entered on this device only). The
  /// values are never logged or displayed.
  Future<void> saveCredentials(int apiId, String apiHash) async {
    try {
      await _credentialsStore.writeApiId(apiId);
      await _credentialsStore.writeApiHash(apiHash);
      await refreshCredentialsStatus();
      _setActionResult('credentials saved');
      _log('credentials saved');
    } catch (e) {
      _setActionResult('save credentials failed: ${_errorLabel(e)}');
      _log('save credentials failed: ${_errorLabel(e)}');
    }
  }

  /// Refreshes whether credentials are stored (yes/no only).
  Future<void> refreshCredentialsStatus() async {
    try {
      final apiId = await _credentialsStore.readApiId();
      final apiHash = await _credentialsStore.readApiHash();
      _credentialsSaved = apiId != null && apiHash != null;
    } catch (_) {
      _credentialsSaved = false;
    }
    notifyListeners();
  }

  /// Refreshes the database key status (present/missing/corrupt/
  /// unreadable). Never the key itself.
  Future<void> refreshKeyStatus() async {
    try {
      final key = await _databaseKeyStore.readKey();
      _keyStatus = key == null ? 'missing' : 'present';
    } on ProviderUnknown catch (e) {
      _keyStatus = switch (e.providerCode) {
        'tdlib_database_key_corrupt' => 'corrupt',
        'tdlib_database_key_unreadable' => 'unreadable',
        _ => 'unknown',
      };
    } catch (_) {
      _keyStatus = 'unknown';
    }
    notifyListeners();
  }

  /// Refreshes the pending/unresolved indicators from the bridge.
  Future<void> refreshPending() async {
    _pendingSetTdlibParameters = _bridge.hasPendingRequest(
      TdlibBridge.setTdlibParametersMethod,
    );
    _unresolvedSetTdlibParameters = _bridge.isRequestUnresolved(
      TdlibBridge.setTdlibParametersMethod,
    );
    _pendingLogOut = _bridge.hasPendingRequest(TdlibBridge.logOutMethod);
    _unresolvedLogOut = _bridge.isRequestUnresolved(TdlibBridge.logOutMethod);
    notifyListeners();
  }

  /// Refreshes the send counts (debug builds only).
  Future<void> refreshSendCounts() async {
    try {
      _sendCounts = await _testHooks.getTestSendCounts();
    } catch (_) {
      _sendCounts = {};
    }
    notifyListeners();
  }

  /// Clears the event log.
  void clearLog() {
    eventLog.clear();
    notifyListeners();
  }

  void _onAuthState(AuthState state) {
    _authState = state;
    _lastError = state is AuthFailed ? state.error : null;
    if (state is AuthAuthenticated) {
      _myId = state.account.accountId.value;
      _qrLink = null;
      _log(
        'auth state: Authenticated '
        '(my_id matches expected: ${myIdMatchesExpected ? 'yes' : 'no'})',
      );
    } else if (state is AuthAwaitingInput) {
      final step = state.step;
      if (step is TelegramOtherDeviceStep) {
        // The link is stored for the screen to render. It is never
        // logged, never put in the event log, never in a report.
        _qrLink = step.link;
        _log('auth state: AwaitingInput (other device — QR)');
      } else {
        _qrLink = null;
        _log('auth state: AwaitingInput (${step.runtimeType})');
      }
    } else {
      if (state is! AuthUnauthenticated) _qrLink = null;
      if (state is AuthFailed) {
        _log('auth state: AuthFailed (${state.error.code})');
      } else {
        _log('auth state: ${_stateName(state)}');
      }
    }
    notifyListeners();
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  void _setActionResult(String result) {
    _lastActionResult = sanitizeLogLine(result);
    notifyListeners();
  }

  void _log(String message) {
    eventLog.add(message);
    notifyListeners();
  }

  static String _stateName(AuthState state) => state.runtimeType.toString();

  static String _errorLabel(Object e) {
    if (e is ProviderError) return e.code;
    return e.runtimeType.toString();
  }

  @override
  void dispose() {
    unawaited(_authSub?.cancel());
    unawaited(_provider?.dispose());
    super.dispose();
  }
}
