import 'account_capabilities.dart';
import 'provider_error.dart';

/// Authentication state of a storage provider, provider-agnostic.
///
/// The interactive steps that lead to these states are provider-specific
/// and travel as [AuthStep] values; TM-Core never interprets them. The
/// authentication feature renders a step by switching on its concrete
/// provider-specific type (see `telegram_auth_steps.dart` for Telegram).
///
/// State machine (all providers):
/// `unauthenticated -> authenticating -> awaitingInput* -> authenticated`
/// or `-> failed`. `signOut()` returns to `unauthenticated`.
sealed class AuthState {
  const AuthState();
}

/// No session exists (or the session was signed out).
final class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated();
}

/// An authentication flow is running (no input needed right now).
final class AuthAuthenticating extends AuthState {
  const AuthAuthenticating();
}

/// The flow waits for the user to complete [step].
final class AuthAwaitingInput extends AuthState {
  const AuthAwaitingInput(this.step);

  final AuthStep step;
}

/// The session is authorized. [account] identifies the account.
final class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(this.account);

  final AccountInfo account;
}

/// The flow ended in failure. [error] explains why.
final class AuthFailed extends AuthState {
  const AuthFailed(this.error);

  final ProviderError error;
}

/// A single interactive authentication step, supplied by the provider.
///
/// TM-Core never interprets steps. The authentication feature switches
/// on the concrete provider-specific type to render the right input.
abstract interface class AuthStep {
  /// Stable kind identifier, e.g. `'telegram_phone'`.
  String get kind;
}

/// Minimal account identity, provider-defined and opaque to TM-Core.
/// For Telegram this is the account's user id as a string. It is an
/// identifier, never a credential.
final class AccountInfo {
  const AccountInfo({required this.accountId, this.displayName});

  final AccountId accountId;

  /// Optional display name supplied by the provider (may be null).
  final String? displayName;
}
