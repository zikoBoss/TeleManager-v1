import 'package:telemanager/providers/telegram/telegram_credentials_store.dart';

/// In-memory [TelegramCredentialsStore] for tests.
final class FakeTelegramCredentialsStore implements TelegramCredentialsStore {
  int? apiId;
  String? apiHash;

  @override
  Future<int?> readApiId() async => apiId;

  @override
  Future<String?> readApiHash() async => apiHash;

  @override
  Future<void> writeApiId(int value) async {
    apiId = value;
  }

  @override
  Future<void> writeApiHash(String value) async {
    apiHash = value;
  }

  @override
  Future<void> clear() async {
    apiId = null;
    apiHash = null;
  }
}
