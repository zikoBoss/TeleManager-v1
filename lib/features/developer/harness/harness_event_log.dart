import 'harness_sanitizer.dart';

/// One sanitized Harness event-log entry.
final class HarnessLogEntry {
  HarnessLogEntry({required this.time, required this.message});

  /// Time the entry was added (local time).
  final DateTime time;

  /// Sanitized message (no secrets — see [sanitizeLogLine]).
  final String message;

  @override
  String toString() {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '[$h:$m:$s.$ms] $message';
  }
}

/// In-memory Harness event log.
///
/// Every entry is sanitized at add time ([sanitizeLogLine]), so the log
/// can be copied and shared without leaking secrets. The log is
/// in-memory only (never written to disk) and holds at most 200 entries
/// (oldest dropped). It never contains: credentials, phone numbers,
/// codes, passwords, QR links, database paths, or encryption keys
/// (only "key present: yes/no").
final class HarnessEventLog {
  static const maxEntries = 200;

  final List<HarnessLogEntry> _entries = [];

  List<HarnessLogEntry> get entries => List.unmodifiable(_entries);

  /// Adds a sanitized entry.
  void add(String message) {
    _entries.add(
      HarnessLogEntry(time: DateTime.now(), message: sanitizeLogLine(message)),
    );
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
  }

  void clear() => _entries.clear();

  /// The whole log as plain text (sanitized), for copying.
  String toText() => _entries.map((e) => e.toString()).join('\n');
}
