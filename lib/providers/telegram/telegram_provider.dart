// ignore_for_file: prefer_initializing_formals
// The constructor's parameters are public named arguments used by callers
// outside this library, while the fields are intentionally private, so
// initializing formals cannot apply here.
import 'dart:async';

import '../account_capabilities.dart';
import '../auth_state.dart';
import '../capability_status.dart';
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
  // Public named parameters (`bridge:` etc.) are part of the API used by
  // callers outside this library, while the fields are intentionally
  // private — initializing formals cannot apply here.
  TelegramProvider({
    required TdlibBridge bridge,
    required TelegramCredentialsStore credentialsStore,
    required String databaseDirectory,
    required String filesDirectory,
    this.applicationVersion = '1.0.0',
    this.closeWaitTimeout = const Duration(seconds: 8),
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

  /// How long [signOut] waits for the `Closed` state after `LogOut`
  /// before giving up. Matches the native Close timeout (8s). On a
  /// timeout the provider does NOT re-initialize the bridge (the old
  /// client may still be closing); the caller should dispose the
  /// provider and create a new one.
  final Duration closeWaitTimeout;

  final _authStates = StreamController<AuthState>.broadcast();
  AuthState _currentAuthState = const AuthUnauthenticated();
  AccountInfo? _currentAccount;
  ProviderError? _lastError;

  var _initialized = false;
  var _disposed = false;
  var _authGeneration = 0;

  /// Generation of the current [authenticate] attempt. Independent of
  /// [_authGeneration] (which counts incoming authorization-state
  /// updates, used only to drop stale [_onReady] results).
  /// Incremented by [_invalidateAuthenticate] whenever the current
  /// attempt is cancelled (by [signOut] or [dispose]); [_authenticate]
  /// captures the value at its start and checks it after every await,
  /// so a late reply can never resume a cancelled attempt.
  var _authenticateGeneration = 0;
  Future<void>? _initializeFuture;
  Future<AuthState>? _authenticateFuture;
  Completer<AuthState>? _authCompleter;
  Completer<void>? _closedCompleter;

  /// Set when a `logOut` (or the following Closed wait) timed out:
  /// the old client may still be closing, so this provider is unsafe
  /// and unusable. A late `Closed` does NOT clear it; only [dispose]
  /// + a new provider recovers.
  var _logoutUnresolved = false;

  /// In-flight `signOut()` operation (single-flight). Concurrent
  /// callers share this exact [Future] object (identical).
  Future<void>? _signOutFuture;
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
    _throwIfUnusable();
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
    _throwIfUnusable();
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
    // Capture the attempt's generation first: every resumption after
    // an await (success or exception) checks it, so a late reply can
    // never resume an attempt that signOut()/dispose() cancelled.
    final generation = _authenticateGeneration;
    int? apiId;
    String? apiHash;
    try {
      apiId = await _credentialsStore.readApiId();
      apiHash = await _credentialsStore.readApiHash();
    } catch (_) {
      // A storage failure after invalidation must not replace the
      // cancellation result with a raw exception.
      if (generation != _authenticateGeneration) {
        return _cancelledAuthenticateResult();
      }
      rethrow;
    }
    if (generation != _authenticateGeneration) {
      return _cancelledAuthenticateResult();
    }
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
    _throwIfPendingRequest(TdlibBridge.setTdlibParametersMethod);
    try {
      await _bridge.setTdlibParameters(
        apiId: apiId,
        apiHash: apiHash,
        databaseDirectory: _databaseDirectory,
        filesDirectory: _filesDirectory,
        applicationVersion: applicationVersion,
      );
    } on ProviderError catch (e) {
      // A late Error (including the technical timeout) must not
      // replace the cancellation result or emit a stale AuthFailed:
      // check the generation before emitting anything.
      if (generation != _authenticateGeneration) {
        return _cancelledAuthenticateResult();
      }
      return _emit(AuthFailed(e));
    } catch (_) {
      if (generation != _authenticateGeneration) {
        return _cancelledAuthenticateResult();
      }
      rethrow;
    }
    // _waitForTerminalAuthState checks the generation first, so a
    // stale attempt never creates a waiter for the new client.
    return _waitForTerminalAuthState(generation);
  }

  Future<AuthState> _waitForTerminalAuthState(int generation) {
    // Check the generation FIRST, before the terminal-state check:
    // a stale attempt must never create a waiter for the new client
    // nor return a terminal state produced by the old client.
    if (generation != _authenticateGeneration) {
      return Future.value(_cancelledAuthenticateResult());
    }
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

  /// The result of an authenticate attempt that was cancelled by
  /// [signOut] (or [dispose], which keeps its own code). Returned
  /// (never emitted) so the stream keeps the provider's true state
  /// ([AuthUnauthenticated] after signOut) while the caller still
  /// gets a diagnosable reason. Follows the [dispose] precedent,
  /// which returns `provider_disposed` the same way.
  AuthState _cancelledAuthenticateResult() {
    if (_disposed) {
      return const AuthFailed(
        ProviderUnknown('provider_disposed', 'TelegramProvider is disposed.'),
      );
    }
    return const AuthFailed(
      ProviderUnknown(
        'authentication_cancelled_by_sign_out',
        'Authentication was cancelled by sign out.',
      ),
    );
  }

  /// Invalidates the current authenticate attempt (if any): a later
  /// resumption of the attempt observes the changed generation and
  /// returns the cancellation result instead of continuing. Also
  /// completes a pending [_authCompleter] with the cancellation
  /// result (then clears it), so a caller waiting on it is freed
  /// promptly. Called from [_signOut] once the sign-out operation
  /// has started, and from [dispose].
  void _invalidateAuthenticate() {
    _authenticateGeneration++;
    final completer = _authCompleter;
    if (completer != null && !completer.isCompleted) {
      _authCompleter = null;
      completer.complete(_cancelledAuthenticateResult());
    }
  }

  /// Signs out and re-creates the client. Concurrent callers share the
  /// same [Future] object (identical), not just the same result.
  ///
  /// The public method is deliberately NOT `async`: an `async`
  /// function always returns a fresh Future wrapping the result, so
  /// `identical` would be false. Here the stored future is returned
  /// directly. The in-flight check comes FIRST, before the guards:
  /// a second call during an in-flight signOut returns the operation
  /// itself even if the provider has since become disposed or
  /// unusable (the operation completes with the appropriate error on
  /// its own). The guards apply only when no operation is in
  /// progress, so a new operation is never started after dispose()
  /// or after a logOut timeout.
  @override
  Future<void> signOut() {
    final inFlight = _signOutFuture;
    if (inFlight != null) return inFlight;
    // Guards throw synchronously in a non-async function; convert
    // them to a failed Future so error delivery matches the async
    // operation (callers uniformly await / expectLater).
    try {
      _throwIfDisposed();
      _throwIfUnusable();
      _throwIfNotInitialized();
    } on ProviderError catch (e) {
      return Future<void>.error(e);
    }
    final future = _signOut();
    _signOutFuture = future;
    // Clear the stored future when it settles, success or error, so
    // a later signOut can start a new operation. `then` with both
    // handlers (not `whenComplete`) so the derived future completes
    // normally in both cases — `whenComplete` would mirror the
    // original's error into an unhandled async error, since nobody
    // awaits the derived future.
    unawaited(
      future.then(
        (_) {
          if (identical(_signOutFuture, future)) _signOutFuture = null;
        },
        onError: (_) {
          if (identical(_signOutFuture, future)) _signOutFuture = null;
        },
      ),
    );
    return future;
  }

  Future<void> _signOut() async {
    _throwIfPendingRequest(TdlibBridge.logOutMethod);
    // Cancel any in-flight authenticate() attempt BEFORE the native
    // logOut starts: the attempt belongs to the client that is about
    // to be closed, so a late reply from it must never resume the
    // attempt (success or error) or create a waiter for the new
    // client. Placed after the pending-request check so a refused
    // signOut does not cancel the attempt, and before logOut so the
    // invalidation also holds if logOut itself times out.
    _invalidateAuthenticate();
    try {
      await _bridge.logOut();
    } on ProviderRequestUnresolved {
      // The logout request timed out: its outcome is unknown and the
      // old client may still be closing. This provider is unusable
      // until dispose() + a new provider; a late Closed alone is not
      // enough to reuse it.
      _logoutUnresolved = true;
      rethrow;
    }
    // If dispose() ran while logOut was in flight, fail promptly
    // instead of waiting up to 8s for a Closed that will never be
    // delivered (the subscription was cancelled in dispose()).
    _throwIfDisposed();
    // logOut() returns when the request is accepted, not when the
    // client is closed. The client is only confirmed closed when the
    // Closed state arrives on authStates (the native side sets
    // closedObserved before the Dart delivery, so the Dart-side Closed
    // is the authoritative signal). Wait for it before re-creating
    // the client: a second client must never be created on the same
    // database before the first is confirmed closed (Task 03/04).
    // A completer (completed in _emit) is used instead of firstWhere
    // on the stream, so a Closed that arrives between the check and
    // the wait cannot be missed.
    if (_currentAuthState is! AuthUnauthenticated) {
      final completer = Completer<void>();
      _closedCompleter = completer;
      try {
        await completer.future.timeout(
          closeWaitTimeout,
          onTimeout: () {
            throw const ProviderNetwork(
              'Timed out waiting for TDLib to close.',
            );
          },
        );
      } on ProviderNetwork {
        // The Closed wait timed out: same unusable rule as a logOut
        // timeout. (Only the timeout throws ProviderNetwork here;
        // dispose() completes this completer with ProviderUnknown,
        // which is not caught.)
        _logoutUnresolved = true;
        rethrow;
      } finally {
        // Clear the waiter whether it completed or timed out; a late
        // Closed is still consumed by _emit (it only moves the state).
        if (identical(_closedCompleter, completer)) _closedCompleter = null;
      }
    }
    // Closed is confirmed: re-create the client so the next
    // authenticate() works without restarting the app. On an
    // unresolved timeout the code above throws, so this is never
    // reached while the old client may still be closing.
    await _bridge.initialize(
      databaseDirectory: _databaseDirectory,
      filesDirectory: _filesDirectory,
    );
  }

  @override
  Future<AccountCapabilities> getAccountCapabilities() async {
    _throwIfDisposed();
    _throwIfUnusable();
    _throwIfNotInitialized();
    final account = _currentAccount;
    if (_currentAuthState is! AuthAuthenticated || account == null) {
      throw const ProviderUnauthenticated();
    }
    // Limits are intentionally unknown: TDLib exposes no capabilities
    // API, and the provider must never invent a limit (audit §C). The
    // server's rejection is authoritative. A verified limit may be set
    // here — in this single place — by a later task.
    //
    // Capability values (see CapabilityStatus): a capability is
    // `supported` only when the library API exists AND TeleManager
    // implements the feature; `conditional` means the library supports
    // it but TeleManager does not implement it yet (the condition is
    // stated here, never implied to be implemented now).
    return AccountCapabilities(
      accountId: account.accountId,
      maxFileSizeBytes: null,
      // No mechanism in TDLib to resume a message send (SendMessage
      // is atomic; PreliminaryUploadFile is for voice/video notes
      // only), and TeleManager does not implement one.
      supportsResumableUpload: CapabilityStatus.unsupported,
      // TDLib's DownloadFile supports an offset, but TeleManager does
      // not use it yet (the provider downloads fresh in Task 06);
      // offset-based resume is planned for Task 11.
      supportsResumableDownload: CapabilityStatus.conditional,
      // Untested (PROJECT_RULES #18): never assume streaming.
      supportsStreaming: CapabilityStatus.unknown,
      maxConcurrentTransfers: null,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Invalidate any in-flight authenticate() attempt first (before
    // the first await below): a late reply resuming after dispose()
    // started must observe the changed generation and return
    // `provider_disposed` instead of continuing. This also completes
    // a pending _authCompleter with that result, so a waiting caller
    // is freed promptly.
    _invalidateAuthenticate();
    // Unblock a signOut() that is waiting for Closed: the provider
    // is going away, so the wait must not hang until its timeout.
    final closedCompleter = _closedCompleter;
    if (closedCompleter != null && !closedCompleter.isCompleted) {
      _closedCompleter = null;
      closedCompleter.completeError(
        const ProviderUnknown(
          'provider_disposed',
          'TelegramProvider is disposed.',
        ),
      );
    }
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
    await _authStates.close();
  }

  // ---- TelegramAuthSteps ----

  @override
  Future<void> submitPhoneNumber(String phoneNumber) async {
    _throwIfDisposed();
    _throwIfUnusable();
    _throwIfNotInitialized();
    _throwIfPendingRequest(TdlibBridge.setAuthenticationPhoneNumberMethod);
    await _bridge.setAuthenticationPhoneNumber(phoneNumber);
  }

  @override
  Future<void> submitCode(String code) async {
    _throwIfDisposed();
    _throwIfUnusable();
    _throwIfNotInitialized();
    _throwIfPendingRequest(TdlibBridge.checkAuthenticationCodeMethod);
    await _bridge.checkAuthenticationCode(code);
  }

  @override
  Future<void> submitPassword(String password) async {
    _throwIfDisposed();
    _throwIfUnusable();
    _throwIfNotInitialized();
    _throwIfPendingRequest(TdlibBridge.checkAuthenticationPasswordMethod);
    await _bridge.checkAuthenticationPassword(password);
  }

  @override
  Future<void> requestQrLogin() async {
    _throwIfDisposed();
    _throwIfUnusable();
    _throwIfNotInitialized();
    _throwIfPendingRequest(TdlibBridge.requestQrCodeAuthenticationMethod);
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
      // The provider was disposed while we waited: drop the result
      // instead of emitting Authenticated on a dead provider.
      if (_disposed) return;
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
    // signOut() waits on this: Closed (the only way to become
    // AuthUnauthenticated) confirms the old client is gone.
    if (state is AuthUnauthenticated) {
      final closedCompleter = _closedCompleter;
      if (closedCompleter != null && !closedCompleter.isCompleted) {
        _closedCompleter = null;
        closedCompleter.complete();
      }
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

  /// Throws when this provider is unusable after an unresolved
  /// logout (see [_logoutUnresolved]). A late Closed does not clear
  /// it; recovery is [dispose] + a new provider. [dispose] itself
  /// is never blocked by this check.
  void _throwIfUnusable() {
    if (_logoutUnresolved) {
      throw const ProviderUnknown(
        'provider_unusable_after_logout',
        'The provider is unusable after an unresolved logout. '
            'Dispose it and create a new provider.',
      );
    }
  }

  /// Refuses a duplicate send while a previous request of the same
  /// method is still outstanding (in flight or timed out but not yet
  /// answered). The bridge tracks the request; the provider enforces
  /// the refusal. A timeout is never a cancellation, so the caller
  /// must not re-send until the late result arrives.
  void _throwIfPendingRequest(String method) {
    if (_bridge.hasPendingRequest(method)) {
      throw ProviderRequestUnresolved(
        method,
        'A previous $method request is still outstanding; refusing '
        'a duplicate send.',
      );
    }
  }

  void _throwIfNotInitialized() {
    if (!_initialized) throw const ProviderNotInitialized();
  }
}
