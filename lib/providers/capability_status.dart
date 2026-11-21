/// Status of a single account capability.
///
/// The three questions behind every value are kept apart:
/// - Does the TDLib library offer the underlying API?
/// - Is the feature implemented in TeleManager right now?
/// - Could it be implemented later, and on what condition?
///
/// `supported` requires BOTH: the library API exists AND TeleManager
/// implements the feature. An API alone never makes a capability
/// `supported`. `conditional` means the library supports it but
/// TeleManager does not implement it yet; the condition that would
/// enable it is stated in the field's documentation — it must never
/// be read as "implemented now".
enum CapabilityStatus {
  /// Implemented and working in TeleManager now.
  supported,

  /// Cannot be provided via the current approach (the library has no
  /// mechanism for it, or the architecture does not allow it).
  unsupported,

  /// Not yet known: untested, unverified, or no authoritative source.
  /// Neither "yes" nor "no".
  unknown,

  /// The library supports it, but TeleManager does not implement it
  /// yet. Available in principle, blocked on a stated condition.
  conditional,
}
