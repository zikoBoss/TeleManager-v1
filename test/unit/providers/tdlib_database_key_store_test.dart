import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/telegram/tdlib_database_key_store.dart';

/// In-memory [FlutterSecureStorage] for tests. Overrides only the
/// methods the key store uses; no platform channel is touched.
final class FakeFlutterSecureStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};

  /// When set, the next read/write/delete throws it (then clears).
  Object? failNext;

  // Signatures match FlutterSecureStorage 11.2.0 exactly (the extra
  // options are accepted and ignored — this fake is in-memory only).
  @override
  Future<String?> read({
    // ignore: unused_element_parameter
    AndroidOptions? aOptions,
    // ignore: unused_element_parameter
    AppleOptions? iOptions,
    required String key,
    // ignore: unused_element_parameter
    LinuxOptions? lOptions,
    // ignore: unused_element_parameter
    AppleOptions? mOptions,
    // ignore: unused_element_parameter
    WindowsOptions? wOptions,
    // ignore: unused_element_parameter
    WebOptions? webOptions,
  }) async {
    final failure = failNext;
    failNext = null;
    if (failure != null) throw failure;
    return values[key];
  }

  @override
  Future<void> write({
    // ignore: unused_element_parameter
    AndroidOptions? aOptions,
    // ignore: unused_element_parameter
    AppleOptions? iOptions,
    required String key,
    // ignore: unused_element_parameter
    LinuxOptions? lOptions,
    // ignore: unused_element_parameter
    AppleOptions? mOptions,
    required String? value,
    // ignore: unused_element_parameter
    WindowsOptions? wOptions,
    // ignore: unused_element_parameter
    WebOptions? webOptions,
  }) async {
    final failure = failNext;
    failNext = null;
    if (failure != null) throw failure;
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    // ignore: unused_element_parameter
    AndroidOptions? aOptions,
    // ignore: unused_element_parameter
    AppleOptions? iOptions,
    required String key,
    // ignore: unused_element_parameter
    LinuxOptions? lOptions,
    // ignore: unused_element_parameter
    AppleOptions? mOptions,
    // ignore: unused_element_parameter
    WindowsOptions? wOptions,
    // ignore: unused_element_parameter
    WebOptions? webOptions,
  }) async {
    final failure = failNext;
    failNext = null;
    if (failure != null) throw failure;
    values.remove(key);
  }
}

/// Expects [error] to be a [ProviderUnknown] with the given
/// [providerCode].
void expectKeyError(Object error, String providerCode) {
  expect(error, isA<ProviderUnknown>());
  expect((error as ProviderUnknown).providerCode, providerCode);
}

void main() {
  group('SecureTdlibDatabaseKeyStore', () {
    late FakeFlutterSecureStorage storage;
    late SecureTdlibDatabaseKeyStore keyStore;

    setUp(() {
      storage = FakeFlutterSecureStorage();
      keyStore = SecureTdlibDatabaseKeyStore(storage);
    });

    test(
      'first creation (no DB, no key): generates and stores a 32-byte key',
      () async {
        final key = await keyStore.getOrCreateKey(databaseExists: false);
        expect(key.length, 32);
        // The stored value is the Base64 of the returned key.
        final stored = storage.values['tdlib_database_key'];
        expect(stored, isNotNull);
        expect(base64Decode(stored!), key);
        // A second call returns the same key (in-memory cache).
        final again = await keyStore.getOrCreateKey(databaseExists: false);
        expect(again, key);
      },
    );

    test('a stored key is returned without generating a new one', () async {
      final preset = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      storage.values['tdlib_database_key'] = base64Encode(preset);
      final key = await keyStore.getOrCreateKey(databaseExists: true);
      expect(key, preset);
      // Still the same stored value (no overwrite).
      expect(storage.values['tdlib_database_key'], base64Encode(preset));
    });

    test('existing DB + missing key: loud failure, no generation', () async {
      await expectLater(
        keyStore.getOrCreateKey(databaseExists: true),
        throwsA(
          isA<ProviderUnknown>().having(
            (e) => e.providerCode,
            'providerCode',
            'tdlib_database_key_missing',
          ),
        ),
      );
      // Nothing was stored.
      expect(storage.values.containsKey('tdlib_database_key'), isFalse);
    });

    test('existing DB + corrupt key: loud failure, no overwrite', () async {
      storage.values['tdlib_database_key'] = 'not-valid-base64!!!';
      await expectLater(
        keyStore.getOrCreateKey(databaseExists: true),
        throwsA(
          isA<ProviderUnknown>().having(
            (e) => e.providerCode,
            'providerCode',
            'tdlib_database_key_corrupt',
          ),
        ),
      );
      // The corrupt value is untouched (not overwritten).
      expect(storage.values['tdlib_database_key'], 'not-valid-base64!!!');
    });

    test('existing DB + wrong-length key: corrupt failure', () async {
      storage.values['tdlib_database_key'] = base64Encode(Uint8List(16));
      await expectLater(
        keyStore.getOrCreateKey(databaseExists: true),
        throwsA(
          isA<ProviderUnknown>().having(
            (e) => e.providerCode,
            'providerCode',
            'tdlib_database_key_corrupt',
          ),
        ),
      );
    });

    test(
      'no DB + corrupt key: clears the corrupt entry and generates',
      () async {
        storage.values['tdlib_database_key'] = 'not-valid-base64!!!';
        final key = await keyStore.getOrCreateKey(databaseExists: false);
        expect(key.length, 32);
        expect(storage.values['tdlib_database_key'], base64Encode(key));
      },
    );

    test('concurrent callers share one generation', () async {
      // Two concurrent calls while no key is stored: only one key is
      // generated and both callers get the same key.
      final results = await Future.wait([
        keyStore.getOrCreateKey(databaseExists: false),
        keyStore.getOrCreateKey(databaseExists: false),
      ]);
      expect(results[0], results[1]);
      expect(results[0].length, 32);
      // One stored value (a single write).
      expect(storage.values.length, 1);
    });

    test('clearKey removes the stored key and the cache', () async {
      final key = await keyStore.getOrCreateKey(databaseExists: false);
      expect(key.length, 32);
      await keyStore.clearKey();
      expect(storage.values.containsKey('tdlib_database_key'), isFalse);
      // A new call generates a fresh key (and it differs: random).
      final fresh = await keyStore.getOrCreateKey(databaseExists: false);
      expect(fresh.length, 32);
      expect(fresh, isNot(key));
    });

    test('secure storage failure is a loud unreadable error', () async {
      storage.failNext = Exception('keystore unavailable');
      await expectLater(
        keyStore.getOrCreateKey(databaseExists: false),
        throwsA(
          isA<ProviderUnknown>().having(
            (e) => e.providerCode,
            'providerCode',
            'tdlib_database_key_unreadable',
          ),
        ),
      );
      // Nothing was stored, and a later call can retry.
      expect(storage.values.containsKey('tdlib_database_key'), isFalse);
      final key = await keyStore.getOrCreateKey(databaseExists: false);
      expect(key.length, 32);
    });

    test('readKey returns null when nothing is stored', () async {
      expect(await keyStore.readKey(), isNull);
    });

    test('readKey throws on a corrupt stored value', () async {
      storage.values['tdlib_database_key'] = 'not-valid-base64!!!';
      await expectLater(
        keyStore.readKey(),
        throwsA(
          isA<ProviderUnknown>().having(
            (e) => e.providerCode,
            'providerCode',
            'tdlib_database_key_corrupt',
          ),
        ),
      );
    });
  });
}
