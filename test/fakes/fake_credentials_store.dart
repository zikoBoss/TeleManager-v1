import 'dart:async';

import 'package:telemanager/providers/telegram/telegram_credentials_store.dart';

/// In-memory [TelegramCredentialsStore] for tests.
final class FakeTelegramCredentialsStore implements TelegramCredentialsStore {
  int? apiId;
  String? apiHash;

  /// When set, the next [readApiId] throws this error (then clears).
  Object? failNextReadApiId;

  /// When set, the next [readApiHash] throws this error (then clears).
  Object? failNextReadApiHash;

  /// When armed by [hangNextRead], the next read waits for
  /// [resolveHungRead] instead of returning immediately (simulating
  /// a slow credentials read that a signOut/dispose can interleave
  /// with). The gate is consumed by whichever read runs first.
  Completer<void>? _hungRead;

  void hangNextRead() {
    _hungRead = Completer<void>();
  }

  void resolveHungRead({Object? error}) {
    final hung = _hungRead;
    _hungRead = null;
    if (hung != null && !hung.isCompleted) {
      if (error != null) {
        hung.completeError(error);
      } else {
        hung.complete();
      }
    }
  }

  @override
  Future<int?> readApiId() async {
    final hung = _hungRead;
    if (hung != null) await hung.future;
    final failure = failNextReadApiId;
    failNextReadApiId = null;
    if (failure != null) throw failure;
    return apiId;
  }

  @override
  Future<String?> readApiHash() async {
    final hung = _hungRead;
    if (hung != null) await hung.future;
    final failure = failNextReadApiHash;
    failNextReadApiHash = null;
    if (failure != null) throw failure;
    return apiHash;
  }

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
