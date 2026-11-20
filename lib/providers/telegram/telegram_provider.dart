import 'dart:async';

import '../account_capabilities.dart';
import '../auth_state.dart';
import '../provider_error.dart';
import '../storage_provider.dart';
import 'tdlib_method_channel.dart';
import 'telegram_auth_steps.dart';
import 'telegram_credentials_store.dart';
import 'telegram_errors.dart';

/// First [StorageProvider] implementation, backed by TDLib.
///
/// Owns exactly one native TDLib client through [TdlibBridge]. The
/// client is created in [initialize] and confirmed closed in [dispose];
/// a second client is never created on the same database (Task 03/04).
///
/// Auth flow (update-driven, no polling): [authenticate] reads the
/// credentials from [TelegramCredentialsStore], sends
/// `SetTdlibParameters`, and completes with the terminal [AuthState].
/// Intermediate states arrive on [authStates]. Interactive steps go
/// through [TelegramAuthSteps].
///
/// Never logs, and never puts credentials, session data, or the QR link
/// into errors, results, or diagnostics (PROJECT_RULES #16). The QR link
/// lives inside [TelegramOtherDeviceStep] in memory only.
final class TelegramProvider implements StorageProvider, TelegramAuthSteps {
  TelegramProvider({
    required TdlibBridge bridge,
    required TelegramCredentialsStore credentialsStore,
    required String databaseDirectory,
    required String filesDirectory,
    this.applicationVersion = '1.0.0',
  }) : _bridge = bridge,
       _credentialsStore = credentialsStore,
       _databaseDirectory = databaseDirectory,
       _filesDirectory = filesDirectory;

  final TdlibBridge _bridge;
  final TelegramCredentialsStore _credentialsStore;
  final String _databaseDirectory;
  final String _filesDirectory;

  /// Version string sent to TDLib as `applicationVersion`.
  final String applicationVersion;

  final _authStates = StreamController<AuthState>.broadcast();
  AuthState _currentAuthState = const AuthUnauthenticated();
  AccountInfo? _currentAccount;
  ProviderError? _lastError;

  var _initialized = false;
  var _disposed = false;
  var _authGeneration = 0;
  Future<void>? _initializeFuture;
  Future<AuthState>? _authenticateFuture;
  Completer<AuthState>? _authCompleter;
  StreamSubscription<TdlibAuthUpdate>? _authUpdatesSub;
  StreamSubscription<TdlibError>? _errorsSub;

  /// Last unsolicited TDLib error (persistent, like the spike's error
  /// line). Diagnostic only; never contains secrets.
  ProviderError? get lastError => _lastError;

  @override
  Stream<AuthState> get authStates => _authStates.stream;

  @override
  AuthState get currentAuthState => _currentAuthState;

  @override
  Future<void> initialize() async {
    _throwIfDisposed();
    if (_initialized) return;
    final inFlight = _initializeFuture;
    if (inFlight != null) return inFlight;
    try {
      _initializeFuture = _initialize();
      await _initializeFuture!;
    } finally {
      _initializeFuture = null;
    }
  }

  Future<void> _initialize() async {
    _authUpdatesSub = _bridge.authUpdates.listen(_onAuthUpdate);
    _errorsSub = _bridge.errors.listen((error) {
      _lastError = mapTdlibError(error.code, error.message);
    });
    try {
      await _bridge.initialize(
        databaseDirectory: _databaseDirectory,
        filesDirectory: _filesDirectory,
      );
    } catch (_) {
      await _authUpdatesSub?.cancel();
      await _errorsSub?.cancel();
      _authUpdatesSub = null;
      _errorsSub = null;
      rethrow;
    }
    _initialized = true;
  }

  @override
  Future<AuthState> authenticate() async {
    _throwIfDisposed();
    _throwIfNotInitialized();
    if (_currentAuthState is AuthAuthenticated) return _currentAuthState;
    final inFlight = _authenticateFuture;
    if (inFlight != null) return inFlight;
    try {
      _authenticateFuture = _authenticate();
      return await _authenticateFuture!;
    } finally {
      _authenticateFuture = null;
    }
  }

  Future<AuthState> _authenticate() async {
    final apiId = await _credentialsStore.readApiId();
    final apiHash = await _credentialsStore.readApiHash();
    if (apiId == null || apiHash == null) {
      return _emit(
        const AuthFailed(
          ProviderUnauthenticated(
            'No Telegram credentials stored. Save the api id and api hash first.',
          ),
        ),
      );
    }
    _emit(const AuthAuthenticating());
    try {
      await _bridge.setTdlibParameters(
        apiId: apiId,
        apiHash: apiHash,
        databaseDirectory: _databaseDirectory,
        filesDirectory: _filesDirectory,
        applicationVersion: applicationVersion,
      );
    } on ProviderError catch (e) {
      return _emit(AuthFailed(e));
    }
    return _waitForTerminalAuthState();
  }

  Future<AuthState> _waitForTerminalAuthState() {
    final current = _currentAuthState;
    if (current is AuthAuthenticated || current is AuthFailed) {
      return Future.value(current);
    }
    // No timeout: the flow legitimately waits for the user (phone /
    // code / QR approval). The caller observes authStates meanwhile.
    final completer = Completer<AuthState>();
    _authCompleter = completer;
    return completer.future;
  }

  @override
  Future<void> signOut() async {
    _throwIfDisposed();
    _throwIfNotInitialized();
    await _bridge.logOut();
    // LoggingOut -> Closed arrive on authStates and move the provider
    // to AuthUnauthenticated.
  }

  @override
  Future<AccountCapabilities> getAccountCapabilities() async {
    _throwIfDisposed();
    _throwIfNotInitialized();
    final account = _currentAccount;
    if (_currentAuthState is! AuthAuthenticated || account == null) {
      throw const ProviderUnauthenticated();
    }
    // Limits are intentionally unknown: TDLib exposes no capabilities
    // API, and the provider must never invent a limit (audit §C). The
    // server's rejection is authoritative. A verified limit may be set
    // here — in this single place — by a later task.
    return AccountCapabilities(
      accountId: account.accountId,
      maxFileSizeBytes: null,
      supportsResumableUpload: false,
      supportsResumableDownload: false,
      supportsStreaming: false,
      maxConcurrentTransfers: null,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _authUpdatesSub?.cancel();
    await _errorsSub?.cancel();
    _authUpdatesSub = null;
    _errorsSub = null;
    if (_initialized) {
      try {
        await _bridge.close();
      } catch (_) {
        // Best-effort: dispose must not throw.
      }
    }
    try {
      await _bridge.dispose();
    } catch (_) {
      // Best-effort.
    }
    final completer = _authCompleter;
    if (completer != null && !completer.isCompleted) {
      _authCompleter = null;
      completer.complete(
        const AuthFailed(
          ProviderUnknown('provider_disposed', 'TelegramProvider is disposed.'),
        ),
      );
    }
    await _authStates.close();
  }

  // ---- TelegramAuthSteps ----

  @override
  Future<void> submitPhoneNumber(String phoneNumber) async {
    _throwIfDisposed();
    _throwIfNotInitialized();
    await _bridge.setAuthenticationPhoneNumber(phoneNumber);
  }

  @override
  Future<void> submitCode(String code) async {
    _throwIfDisposed();
    _throwIfNotInitialized();
    await _bridge.checkAuthenticationCode(code);
  }

  @override
  Future<void> submitPassword(String password) async {
    _throwIfDisposed();
    _throwIfNotInitialized();
    await _bridge.checkAuthenticationPassword(password);
  }

  @override
  Future<void> requestQrLogin() async {
    _throwIfDisposed();
    _throwIfNotInitialized();
    await _bridge.requestQrCodeAuthentication();
  }

  // ---- state machine ----

  void _onAuthUpdate(TdlibAuthUpdate update) {
    _authGeneration++;
    if (update.state == 'AuthorizationStateReady') {
      // Ready needs the account id (async); handle it separately so
      // the emitted AuthAuthenticated always carries a valid account.
      unawaited(_onReady());
      return;
    }
    _emit(_mapAuthUpdate(update));
  }

  Future<void> _onReady() async {
    final generation = _authGeneration;
    try {
      final myId = await _bridge.getMyId();
      // A newer state arrived while we waited (e.g. Closing): drop
      // this stale result instead of emitting an outdated Authenticated.
      if (generation != _authGeneration) return;
      if (myId == 0) {
        _emit(
          const AuthFailed(
            ProviderUnknown(
              'my_id_zero',
              'Authorized but no user id was returned.',
            ),
          ),
        );
        return;
      }
      _emit(
        AuthAuthenticated(AccountInfo(accountId: AccountId(myId.toString()))),
      );
    } on ProviderError catch (e) {
      if (generation != _authGeneration) return;
      _emit(AuthFailed(e));
    } catch (_) {
      // _onReady runs unawaited: never let an unexpected failure
      // escape as an unhandled async error.
      if (generation != _authGeneration) return;
      _emit(
        const AuthFailed(
          ProviderUnknown(
            'my_id_failed',
            'Failed to read the user id after authorization.',
          ),
        ),
      );
    }
  }

  AuthState _mapAuthUpdate(TdlibAuthUpdate update) {
    switch (update.state) {
      case 'AuthorizationStateWaitTdlibParameters':
      case 'AuthorizationStateLoggingOut':
      case 'AuthorizationStateClosing':
        return const AuthAuthenticating();
      case 'AuthorizationStateWaitPhoneNumber':
        return const AuthAwaitingInput(TelegramPhoneStep());
      case 'AuthorizationStateWaitEmailAddress':
        return const AuthAwaitingInput(TelegramEmailAddressStep());
      case 'AuthorizationStateWaitEmailCode':
        return AuthAwaitingInput(
          TelegramEmailCodeStep(
            emailAddressPattern: update.emailAddressPattern ?? '',
            length: update.emailCodeLength ?? 0,
          ),
        );
      case 'AuthorizationStateWaitCode':
        return AuthAwaitingInput(
          TelegramCodeStep(_parseCodeInfo(update.codeInfo)),
        );
      case 'AuthorizationStateWaitRegistration':
        return const AuthAwaitingInput(TelegramRegistrationStep());
      case 'AuthorizationStateWaitPassword':
        return AuthAwaitingInput(
          TelegramPasswordStep(update.passwordHint ?? ''),
        );
      case 'AuthorizationStateWaitOtherDeviceConfirmation':
        return AuthAwaitingInput(TelegramOtherDeviceStep(update.qrLink ?? ''));
      case 'AuthorizationStateWaitPremiumPurchase':
        return const AuthAwaitingInput(TelegramPremiumStep());
      case 'AuthorizationStateClosed':
        return const AuthUnauthenticated();
      default:
        // Unknown state (e.g. a newer TDLib added one): fail loudly
        // rather than hanging. The 13 states above are exhaustive for
        // TDLib 1.8.67 (verified by javap in Task 04).
        return AuthFailed(
          ProviderUnknown(
            'unknown_authorization_state',
            'Unknown authorization state: ${update.state}',
          ),
        );
    }
  }

  TelegramCodeInfo _parseCodeInfo(Map<String, Object?>? raw) {
    if (raw == null) {
      return const TelegramCodeInfo(
        typeName: '',
        typeLength: 0,
        timeoutSeconds: 0,
      );
    }
    final type = raw['type'];
    final nextType = raw['nextType'];
    var typeName = '';
    var typeLength = 0;
    if (type is Map) {
      typeName = type['name'] as String? ?? '';
      typeLength = type['length'] as int? ?? 0;
    }
    String? nextTypeName;
    int? nextTypeLength;
    if (nextType is Map) {
      nextTypeName = nextType['name'] as String?;
      nextTypeLength = nextType['length'] as int?;
    }
    return TelegramCodeInfo(
      typeName: typeName,
      typeLength: typeLength,
      nextTypeName: nextTypeName,
      nextTypeLength: nextTypeLength,
      timeoutSeconds: raw['timeoutSeconds'] as int? ?? 0,
    );
  }

  AuthState _emit(AuthState state) {
    _currentAuthState = state;
    if (state is AuthAuthenticated) {
      _currentAccount = state.account;
    } else if (state is AuthUnauthenticated || state is AuthFailed) {
      _currentAccount = null;
    }
    if (!_authStates.isClosed) _authStates.add(state);
    final completer = _authCompleter;
    if (completer != null &&
        !completer.isCompleted &&
        (state is AuthAuthenticated || state is AuthFailed)) {
      _authCompleter = null;
      completer.complete(state);
    }
    return state;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw const ProviderUnknown(
        'provider_disposed',
        'TelegramProvider is disposed.',
      );
    }
  }

  void _throwIfNotInitialized() {
    if (!_initialized) throw const ProviderNotInitialized();
  }
}
