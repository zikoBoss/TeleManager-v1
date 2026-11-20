import 'package:flutter_test/flutter_test.dart';
import 'package:telemanager/providers/provider_error.dart';
import 'package:telemanager/providers/telegram/telegram_errors.dart';

void main() {
  group('mapTdlibError', () {
    test('FLOOD_WAIT_60 maps to ProviderFloodWait with 60s', () {
      final error = mapTdlibError(429, 'FLOOD_WAIT_60');
      expect(error, isA<ProviderFloodWait>());
      expect(
        (error as ProviderFloodWait).retryAfter,
        const Duration(seconds: 60),
      );
    });

    test('FLOOD_WAIT without a number falls through (no invented duration)', () {
      // Code 400 + unparsable FLOOD_WAIT_ -> no flood-wait branch, no
      // other branch matches -> unknown (the 429 fallback needs a 429).
      final error = mapTdlibError(400, 'FLOOD_WAIT_');
      expect(error, isA<ProviderUnknown>());
    });

    test('401 maps to unauthenticated', () {
      expect(
        mapTdlibError(401, 'Unauthorized'),
        isA<ProviderUnauthenticated>(),
      );
    });

    test('AUTH_KEY_UNREGISTERED maps to unauthenticated', () {
      expect(
        mapTdlibError(400, 'AUTH_KEY_UNREGISTERED'),
        isA<ProviderUnauthenticated>(),
      );
    });

    test('SESSION_REVOKED maps to unauthenticated (no wipe implied)', () {
      expect(
        mapTdlibError(400, 'SESSION_REVOKED'),
        isA<ProviderUnauthenticated>(),
      );
    });

    test('PHONE_CODE_INVALID maps to invalid input, not delivery proof', () {
      final error = mapTdlibError(400, 'PHONE_CODE_INVALID');
      expect(error, isA<ProviderInvalidInput>());
    });

    test('resend refusal maps to invalid input', () {
      final error =
          mapTdlibError(400, "Authentication code can't be resend");
      expect(error, isA<ProviderInvalidInput>());
    });

    test('404 maps to not found', () {
      expect(mapTdlibError(404, 'Not Found'), isA<ProviderNotFound>());
    });

    test('403 maps to permission denied', () {
      expect(
        mapTdlibError(403, 'Forbidden'),
        isA<ProviderPermissionDenied>(),
      );
    });

    test('bare 429 maps to flood wait with the documented fallback', () {
      final error = mapTdlibError(429, 'Too Many Requests');
      expect(error, isA<ProviderFloodWait>());
      expect(
        (error as ProviderFloodWait).retryAfter,
        const Duration(seconds: 60),
      );
    });

    test('network messages map to network', () {
      expect(
        mapTdlibError(0, 'Network is unreachable'),
        isA<ProviderNetwork>(),
      );
    });

    test('unknown errors keep the provider code', () {
      final error = mapTdlibError(500, 'Internal Server Error');
      expect(error, isA<ProviderUnknown>());
      expect((error as ProviderUnknown).providerCode, '500');
    });

    test('error codes are distinct and stable', () {
      expect(const ProviderUnauthenticated().code, 'unauthenticated');
      expect(
        const ProviderFloodWait(Duration(seconds: 1)).code,
        'flood_wait',
      );
      expect(const ProviderNotInitialized().code, 'not_initialized');
      expect(const ProviderCancelled().code, 'cancelled');
    });
  });
}
