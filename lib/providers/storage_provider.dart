import 'account_capabilities.dart';
import 'auth_state.dart';
import 'provider_error.dart';

/// Storage provider contract (TM-Cloud). Provider-agnostic: TM-Core
/// only ever sees these types, never Telegram/TDLib types.
///
/// Based on Master Blueprint §5 (conceptual interface, adjusted for
/// TDLib's needs — the Blueprint states it is preliminary, not final).
/// `docs/INTERFACES.md` is the contract reference (PROJECT_RULES #23).
///
/// Lifecycle: `initialize()` -> `authenticate()` -> operations ->
/// `dispose()`. `initialize()` is idempotent; `dispose()` is terminal.
/// Transfer operations live on the separate [StorageOperations]
/// interface (defined in Task 05, implemented in Task 06) so that no
/// Task 05 code ships an unimplemented method or a fake result.
abstract interface class StorageProvider {
  /// Creates the provider's client and resources. Idempotent: calling
  /// it twice does not create a second client. Must be called before
  /// any other method; the other methods throw [ProviderNotInitialized]
  /// before initialization (except [authStates], [currentAuthState] and
  /// [dispose], which are always safe to use).
  Future<void> initialize();

  /// Stream of authentication states. Broadcast, so the UI and
  /// TM-Transfer may both listen. Read [currentAuthState] for the
  /// latest state; the stream carries changes.
  Stream<AuthState> get authStates;

  /// Latest authentication state, synchronously.
  AuthState get currentAuthState;

  /// Starts (or resumes) authentication. Completes with the terminal
  /// state: [AuthAuthenticated] or [AuthFailed]. Intermediate states
  /// arrive on [authStates]. Interactive steps are provider-specific
  /// (see `TelegramAuthSteps` for Telegram); this method does not
  /// itself collect user input. When a session already exists it is
  /// restored and the result is [AuthAuthenticated].
  Future<AuthState> authenticate();

  /// Signs out and wipes the local session, per user choice
  /// (Blueprint §7.1 step 8). After sign-out the provider is
  /// unauthenticated but still usable: [authenticate] may run again.
  Future<void> signOut();

  /// Capabilities of the authenticated account. Requires an
  /// authenticated session; otherwise throws [ProviderUnauthenticated].
  Future<AccountCapabilities> getAccountCapabilities();

  /// Terminal: closes the provider's client and releases resources.
  /// Idempotent and safe to call at any time. After dispose the
  /// provider must not be used; create a new instance instead.
  Future<void> dispose();
}
