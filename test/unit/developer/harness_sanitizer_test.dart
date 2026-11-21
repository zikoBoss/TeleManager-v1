import 'package:flutter_test/flutter_test.dart';
import 'package:telemanager/features/developer/harness/harness_sanitizer.dart';

void main() {
  group('sanitizeLogLine', () {
    test('a clean line is unchanged', () {
      const line = '[12:00:00] auth state: Authenticated (my_id matches: yes)';
      expect(sanitizeLogLine(line), line);
      expect(isLogLineClean(line), isTrue);
    });

    test('a tg:// login link is redacted', () {
      const link = 'tg://login?token=abc123';
      final line = 'state: $link';
      final sanitized = sanitizeLogLine(line);
      expect(sanitized, isNot(contains(link)));
      expect(sanitized, isNot(contains('abc123')));
      expect(sanitized, contains('[auth-link-redacted]'));
      expect(isLogLineClean(sanitized), isTrue);
    });

    test('a 32-byte Base64 key is redacted', () {
      // 44 characters, Base64 alphabet, ending in '='.
      const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh4=';
      expect(key.length, 44);
      final line = 'key: $key';
      final sanitized = sanitizeLogLine(line);
      expect(sanitized, isNot(contains(key)));
      expect(sanitized, contains('[key-redacted]'));
    });

    test('an international phone number is redacted', () {
      const phone = '+212612345678';
      final line = 'code sent to $phone';
      final sanitized = sanitizeLogLine(line);
      expect(sanitized, isNot(contains(phone)));
      expect(sanitized, contains('[phone-redacted]'));
    });

    test('multiple secrets in one line are all redacted', () {
      const line =
          'tg://login?token=x +212612345678 '
          'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh4=';
      final sanitized = sanitizeLogLine(line);
      expect(sanitized, contains('[auth-link-redacted]'));
      expect(sanitized, contains('[phone-redacted]'));
      expect(sanitized, contains('[key-redacted]'));
      expect(isLogLineClean(sanitized), isTrue);
    });
  });
}
