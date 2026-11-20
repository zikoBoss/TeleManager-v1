import '../auth_state.dart';

/// Interactive authentication steps specific to Telegram (TDLib).
///
/// The authentication feature uses this interface when the active
/// provider is Telegram. TM-Core never sees these methods or types:
/// it only ever observes the generic [AuthState] stream.
///
/// A step method returns when the request was accepted by TDLib; the
/// resulting state arrives on [StorageProvider.authStates]. A rejected
/// step throws the mapped [ProviderError] (e.g. a wrong code throws
/// [ProviderInvalidInput]).
abstract interface class TelegramAuthSteps {
  /// Submits the phone number and requests a verification code.
  Future<void> submitPhoneNumber(String phoneNumber);

  /// Submits the verification code the user received.
  Future<void> submitCode(String code);

  /// Submits the Two-Step Verification password.
  Future<void> submitPassword(String password);

  /// Requests QR-code login (scan in the official app on the account).
  /// The confirmation link is delivered inside a
  /// [TelegramOtherDeviceStep] and is a login token: in-memory only.
  Future<void> requestQrLogin();
}

/// The flow waits for a phone number.
final class TelegramPhoneStep implements AuthStep {
  const TelegramPhoneStep();

  @override
  String get kind => 'telegram_phone';
}

/// The flow waits for an email address (TDLib email auth path).
final class TelegramEmailAddressStep implements AuthStep {
  const TelegramEmailAddressStep();

  @override
  String get kind => 'telegram_email_address';
}

/// The flow waits for a code sent to an email address.
/// [emailAddressPattern] is TDLib's masked pattern (display only).
final class TelegramEmailCodeStep implements AuthStep {
  const TelegramEmailCodeStep({
    required this.emailAddressPattern,
    required this.length,
  });

  final String emailAddressPattern;
  final int length;

  @override
  String get kind => 'telegram_email_code';
}

/// Code information for a WaitCode state, mirroring the spike's
/// `CodeInfoReport`: type + next type + timeout only. The phone number
/// and verifier data are never recorded.
final class TelegramCodeInfo {
  const TelegramCodeInfo({
    required this.typeName,
    required this.typeLength,
    this.nextTypeName,
    this.nextTypeLength,
    required this.timeoutSeconds,
  });

  /// Current code channel, e.g. `AuthenticationCodeTypeTelegramMessage`.
  final String typeName;

  /// Expected code length (5 for the Telegram-message channel).
  final int typeLength;

  /// Next resend channel, or `null` when the server offers none.
  final String? nextTypeName;

  /// Length of the next channel's code, when there is one.
  final int? nextTypeLength;

  /// Seconds until a resend is allowed (0 when no resend is offered).
  final int timeoutSeconds;

  /// Whether a resend is possible at all (server decision).
  bool get canResend => nextTypeName != null;
}

/// The flow waits for a verification code.
final class TelegramCodeStep implements AuthStep {
  const TelegramCodeStep(this.codeInfo);

  final TelegramCodeInfo codeInfo;

  @override
  String get kind => 'telegram_code';
}

/// The flow waits for the Two-Step Verification password.
/// [hint] is TDLib's password hint: display only, never logged.
final class TelegramPasswordStep implements AuthStep {
  const TelegramPasswordStep(this.hint);

  final String hint;

  @override
  String get kind => 'telegram_password';
}

/// The flow waits for confirmation on another device (QR login).
///
/// [link] is the TDLib confirmation link: a login token. It lives in
/// memory only — never logged, persisted, or put in diagnostics — and
/// must be dropped when the state leaves WaitOtherDeviceConfirmation.
/// The UI renders it as a QR image; it is never shown as text.
final class TelegramOtherDeviceStep implements AuthStep {
  const TelegramOtherDeviceStep(this.link);

  final String link;

  @override
  String get kind => 'telegram_other_device';
}

/// The account needs registration (new account). Display-only: this
/// spike/provider does not register accounts.
final class TelegramRegistrationStep implements AuthStep {
  const TelegramRegistrationStep();

  @override
  String get kind => 'telegram_registration';
}

/// The flow waits for a Premium purchase. Display-only.
final class TelegramPremiumStep implements AuthStep {
  const TelegramPremiumStep();

  @override
  String get kind => 'telegram_premium';
}
