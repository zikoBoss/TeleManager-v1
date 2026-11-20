import 'dart:async';

import 'package:telemanager/providers/account_capabilities.dart';
import 'package:telemanager/providers/auth_state.dart';
import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/storage_provider.dart';

/// Minimal in-memory [StorageProvider] used ONLY as the reference
/// implementation for the contract suite (PROJECT_RULES #14). It
/// implements the contract's behavior with no TDLib and no network.
///
/// Set [hasCredentials] to make [authenticate] succeed; without
/// credentials it completes with [AuthFailed] (never a throw), exactly
/// like the real provider.
final class FakeStorageProvider implements StorageProvider {
  FakeStorageProvider({this.hasCredentials = false});

  bool hasCredentials;

  final _authStates = StreamController<AuthState>.broadcast();
  AuthState _current = const AuthUnauthenticated();
  var _initialized = false;
  var _disposed = false;

  @override
  Stream<AuthState> get authStates => _authStates.stream;

  @override
  AuthState get currentAuthState => _current;

  @override
  Future<void> initialize() async {
    _throwIfDisposed();
    _initialized = true;
  }

  @override
  Future<AuthState> authenticate() async {
    _throwIfDisposed();
    _throwIfNotInitialized();
    if (_current is AuthAuthenticated) return _current;
    if (!hasCredentials) {
      return _emit(
        const AuthFailed(ProviderUnauthenticated('No credentials.')),
      );
    }
    return _emit(
      const AuthAuthenticated(
        AccountInfo(accountId: AccountId('fake-account')),
      ),
    );
  }

  @override
  Future<void> signOut() async {
    _throwIfDisposed();
    _throwIfNotInitialized();
    _emit(const AuthUnauthenticated());
  }

  @override
  Future<AccountCapabilities> getAccountCapabilities() async {
    _throwIfDisposed();
    _throwIfNotInitialized();
    if (_current is! AuthAuthenticated) {
      throw const ProviderUnauthenticated();
    }
    final account = (_current as AuthAuthenticated).account;
    return AccountCapabilities(accountId: account.accountId);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _authStates.close();
  }

  AuthState _emit(AuthState state) {
    _current = state;
    if (!_authStates.isClosed) _authStates.add(state);
    return state;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw const ProviderUnknown(
        'provider_disposed',
        'FakeStorageProvider is disposed.',
      );
    }
  }

  void _throwIfNotInitialized() {
    if (!_initialized) throw const ProviderNotInitialized();
  }
}
