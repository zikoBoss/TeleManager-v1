import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../provider_error.dart';

/// Secure storage for the TDLib database encryption key.
///
/// The TDLib database is encrypted with a 32-byte key (AES-256). The key
/// must be the same on every launch, or TDLib cannot open the database.
/// It is stored in `flutter_secure_storage` (Android Keystore-backed),
/// the same mechanism as the API credentials.
///
/// Safety rules (enforced by [getOrCreateKey]):
/// - A key is generated ONLY when no TDLib database exists yet
///   ([databaseExists] == false). An existing database without a stored
///   key is a loud failure, never a silent regeneration (which would
///   orphan the session).
/// - Concurrent callers share one in-flight operation (single-flight),
///   so the key is never generated or saved twice.
/// - The key is bytes end-to-end. It is never logged, never put in
///   errors, results, or diagnostics, and never converted to a string
///   for display (not even its Base64 form).
abstract interface class TdlibDatabaseKeyStore {
  /// Stored key bytes, or `null` when none was saved.
  /// Throws [ProviderUnknown] (`tdlib_database_key_corrupt`) when the
  /// stored value cannot be decoded or has the wrong length, and
  /// (`tdlib_database_key_unreadable`) when secure storage fails.
  Future<Uint8List?> readKey();

  /// Generates a new 32-byte key, stores it, and returns it.
  /// Called only when the caller has established that no database
  /// exists yet (see [getOrCreateKey]).
  Future<Uint8List> createKey();

  /// Deletes the stored key. Used only by the explicit "reset test
  /// session" flow (which also deletes the database directory).
  Future<void> clearKey();

  /// Returns the key to use for the database.
  ///
  /// - A stored, valid key is returned (and cached in memory).
  /// - No stored key and no database ([databaseExists] == false):
  ///   a new key is generated, stored, and returned.
  /// - No stored key and an existing database: throws [ProviderUnknown]
  ///   (`tdlib_database_key_missing`); no key is generated.
  /// - A stored but corrupt key: throws (`tdlib_database_key_corrupt`)
  ///   when a database exists; when no database exists the corrupt
  ///   entry is cleared and a fresh key is generated.
  ///
  /// Concurrent callers share the same in-flight operation.
  Future<Uint8List> getOrCreateKey({required bool databaseExists});
}

/// Keystore/Keychain-backed implementation via `flutter_secure_storage`.
final class SecureTdlibDatabaseKeyStore implements TdlibDatabaseKeyStore {
  SecureTdlibDatabaseKeyStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _keyStorageKey = 'tdlib_database_key';

  /// 32 bytes (256 bits) for AES-256.
  static const keyLengthBytes = 32;

  final FlutterSecureStorage _storage;

  /// In-memory cache after a successful read or generation. Cleared
  /// only by [clearKey]. Never logged.
  Uint8List? _cachedKey;

  /// In-flight [getOrCreateKey] operation (single-flight). Cleared on
  /// error so a later call can retry; on success the cache holds the key.
  Future<Uint8List>? _keyFuture;

  @override
  Future<Uint8List?> readKey() async {
    final raw = await _readRaw();
    if (raw == null) return null;
    return _decodeKey(raw);
  }

  @override
  Future<Uint8List> createKey() async {
    final key = Uint8List(keyLengthBytes);
    final random = Random.secure();
    for (var i = 0; i < key.length; i++) {
      key[i] = random.nextInt(256);
    }
    await _writeRaw(base64Encode(key));
    _cachedKey = key;
    return key;
  }

  @override
  Future<void> clearKey() async {
    _cachedKey = null;
    _keyFuture = null;
    await _deleteRaw();
  }

  @override
  Future<Uint8List> getOrCreateKey({required bool databaseExists}) {
    final cached = _cachedKey;
    if (cached != null) return Future.value(cached);
    final inFlight = _keyFuture;
    if (inFlight != null) return inFlight;
    _keyFuture = _getOrCreateKeyInternal(databaseExists: databaseExists);
    return _keyFuture!;
  }

  Future<Uint8List> _getOrCreateKeyInternal({
    required bool databaseExists,
  }) async {
    try {
      final raw = await _readRaw();
      if (raw != null) {
        // A stored key exists. Validate it; a corrupt value is an error
        // when a database exists, and is cleared + regenerated only
        // when no database exists.
        try {
          final key = _decodeKey(raw);
          _cachedKey = key;
          return key;
        } on ProviderUnknown {
          if (databaseExists) rethrow;
          // No database exists: the corrupt entry is worthless, so
          // clear it and generate a fresh key.
          await _deleteRaw();
          return await createKey();
        }
      }
      // No stored key.
      if (databaseExists) {
        throw const ProviderUnknown(
          'tdlib_database_key_missing',
          'TDLib database exists but its encryption key is missing; '
              'the session cannot be recovered. Reset the test session '
              'to start fresh.',
        );
      }
      return await createKey();
    } catch (_) {
      // A failed operation must not leave a stale in-flight future:
      // a later call retries.
      _keyFuture = null;
      rethrow;
    }
  }

  /// Decodes a stored Base64 key and validates its length. Throws
  /// [ProviderUnknown] (`tdlib_database_key_corrupt`) on any problem.
  /// Never includes the stored value in the error.
  Uint8List _decodeKey(String raw) {
    Uint8List key;
    try {
      key = base64Decode(raw);
    } on FormatException {
      throw const ProviderUnknown(
        'tdlib_database_key_corrupt',
        'Stored TDLib database key is corrupt and cannot be decoded.',
      );
    }
    if (key.length != keyLengthBytes) {
      throw const ProviderUnknown(
        'tdlib_database_key_corrupt',
        'Stored TDLib database key has the wrong length.',
      );
    }
    return key;
  }

  Future<String?> _readRaw() async {
    try {
      return await _storage.read(key: _keyStorageKey);
    } on Exception {
      throw const ProviderUnknown(
        'tdlib_database_key_unreadable',
        'TDLib database key could not be read from secure storage.',
      );
    }
  }

  Future<void> _writeRaw(String value) async {
    try {
      await _storage.write(key: _keyStorageKey, value: value);
    } on Exception {
      throw const ProviderUnknown(
        'tdlib_database_key_unreadable',
        'TDLib database key could not be written to secure storage.',
      );
    }
  }

  Future<void> _deleteRaw() async {
    try {
      await _storage.delete(key: _keyStorageKey);
    } on Exception {
      throw const ProviderUnknown(
        'tdlib_database_key_unreadable',
        'TDLib database key could not be deleted from secure storage.',
      );
    }
  }
}
