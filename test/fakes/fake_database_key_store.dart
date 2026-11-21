import 'dart:typed_data';

import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/telegram/tdlib_database_key_store.dart';

/// In-memory [TdlibDatabaseKeyStore] for tests.
///
/// Explicitly a test double (PROJECT_RULES #14). The stored key is a
/// fixed test value (never a real key) and is never logged.
final class FakeTdlibDatabaseKeyStore implements TdlibDatabaseKeyStore {
  /// Fixed test key (32 bytes). Tests may replace it.
  Uint8List testKey = Uint8List.fromList(List.generate(32, (i) => i));

  /// Stored key bytes, or `null` when none was saved. Tests set this
  /// directly to simulate a stored key, or leave it `null`.
  Uint8List? storedKey;

  /// When set, [readKey] throws this error (then clears).
  Object? failNextRead;

  /// When set, [createKey] throws this error (then clears).
  Object? failNextCreate;

  /// How many times [createKey] was called (proves single generation).
  int createKeyCalls = 0;

  /// The `databaseExists` flags passed to [getOrCreateKey], in order.
  final List<bool> getOrCreateDatabaseExistsArgs = [];

  @override
  Future<Uint8List?> readKey() async {
    final failure = failNextRead;
    failNextRead = null;
    if (failure != null) throw failure;
    return storedKey;
  }

  @override
  Future<Uint8List> createKey() async {
    createKeyCalls++;
    final failure = failNextCreate;
    failNextCreate = null;
    if (failure != null) throw failure;
    storedKey = testKey;
    return testKey;
  }

  @override
  Future<void> clearKey() async {
    storedKey = null;
  }

  @override
  Future<Uint8List> getOrCreateKey({required bool databaseExists}) async {
    getOrCreateDatabaseExistsArgs.add(databaseExists);
    final stored = await readKey();
    if (stored != null) return stored;
    if (databaseExists) {
      throw const ProviderUnknown(
        'tdlib_database_key_missing',
        'TDLib database exists but its encryption key is missing.',
      );
    }
    return createKey();
  }
}
