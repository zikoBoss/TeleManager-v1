import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage for the Telegram API credentials (`api_id` / `api_hash`).
///
/// The provider reads credentials through this interface; the
/// authentication feature writes them. Credentials are never logged,
/// never put in results or diagnostics, and never stored in plaintext
/// preferences (the spike's SharedPreferences approach is spike-only).
///
/// Keys are fixed and namespaced so a future migration can find them.
abstract interface class TelegramCredentialsStore {
  /// Stored api id, or `null` when none was saved.
  Future<int?> readApiId();

  /// Stored api hash, or `null` when none was saved.
  Future<String?> readApiHash();

  /// Saves the api id.
  Future<void> writeApiId(int apiId);

  /// Saves the api hash.
  Future<void> writeApiHash(String apiHash);

  /// Deletes both stored credentials.
  Future<void> clear();
}

/// Keystore/Keychain-backed implementation via `flutter_secure_storage`.
final class SecureTelegramCredentialsStore implements TelegramCredentialsStore {
  SecureTelegramCredentialsStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _apiIdKey = 'telegram_api_id';
  static const _apiHashKey = 'telegram_api_hash';

  final FlutterSecureStorage _storage;

  @override
  Future<int?> readApiId() async {
    final raw = await _storage.read(key: _apiIdKey);
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  @override
  Future<String?> readApiHash() => _storage.read(key: _apiHashKey);

  @override
  Future<void> writeApiId(int apiId) =>
      _storage.write(key: _apiIdKey, value: apiId.toString());

  @override
  Future<void> writeApiHash(String apiHash) =>
      _storage.write(key: _apiHashKey, value: apiHash);

  @override
  Future<void> clear() async {
    await _storage.delete(key: _apiIdKey);
    await _storage.delete(key: _apiHashKey);
  }
}
