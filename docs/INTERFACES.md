# TeleManager — العقود البرمجية العامة

## الحالة الحالية
نسخة تأسيسية (Draft) مع أول عقدين في المهمة 05: `StorageProvider` و`StorageOperations` (التعريف) و`TelegramProvider` (دورة الحياة والمصادقة والقدرات). العقود المنفذة موثقة بالتواقيع الفعلية أدناه ومطابقة للكود والاختبارات. باقي البنود حدود معمارية مطلوبة من `MASTER_BLUEPRINT.md` وستتحول إلى عقود دقيقة عند كتابة كل وحدة واختبارها.

## قواعد تحديث هذا الملف
1. حدّث الوثيقة مع أي إنشاء/تعديل/حذف لعقد يعبر حدود وحدتين.
2. وثّق التواقيع الفعلية، أنواع المدخلات والمخرجات، الأخطاء، دورة الحياة والتزامن والإلغاء والموارد عند انطباقها.
3. طابق النص مع الكود والاختبارات؛ لا تخترع دوالًا أو معاملات.
4. عند تعديل عقد قائم، اذكر المستهلكين وأثر التغيير وخطة التوافق/الترحيل.

## العقود

### `StorageProvider` — يملكه TM-Cloud (منفذ في المهمة 05)
الملف: `lib/providers/storage_provider.dart`. التنفيذ الأول: `TelegramProvider` في `lib/providers/telegram/telegram_provider.dart` (عبر جسر MethodChannel إلى Kotlin في `android/native/tdlib_bridge/TdlibBridge.kt`).

المسؤولية: واجهة مستقلة عن المزود للتهيئة والمصادقة وقدرات الحساب. لا تعرف TM-Core أي نوع خاص بـTelegram أو TDLib.

التواقيع (Dart):
```dart
abstract interface class StorageProvider {
  Future<void> initialize();
  Stream<AuthState> get authStates;
  AuthState get currentAuthState;
  Future<AuthState> authenticate();
  Future<void> signOut();
  Future<AccountCapabilities> getAccountCapabilities();
  Future<void> dispose();
}
```

نماذج البيانات:
- `AuthState` (sealed): `AuthUnauthenticated`، `AuthAuthenticating`، `AuthAwaitingInput(AuthStep)`، `AuthAuthenticated(AccountInfo)`، `AuthFailed(ProviderError)`.
- `AuthStep`: واجهة خطوة تفاعلية (`kind`)؛ الأنواع الخاصة بـTelegram في `lib/providers/telegram/telegram_auth_steps.dart` (هاتف، رمز مع `TelegramCodeInfo`، كلمة مرور مع hint، جهاز آخر مع رابط QR في الذاكرة فقط، بريد، تسجيل، Premium).
- `AccountInfo`: `accountId` (معتم) و`displayName?`.
- `AccountCapabilities`: `accountId`، `maxFileSizeBytes?` (null = غير معروف/الخادم يحسم)، وثلاثة أعلام من نوع `CapabilityStatus` (`supported`/`unsupported`/`unknown`/`conditional` — في `lib/providers/capability_status.dart`) بدل `bool`: فـ `bool` لا يميز "غير مدعوم" عن "غير معروف" عن "تدعمه المكتبة ولم ينفذه TeleManager بعد". و`supported` تتطلب الأمرين معًا (API المكتبة + تنفيذ فعلي)؛ و`conditional` تعني أن المكتبة تدعمها وTeleManager لا ينفذها بعد (والشرط مذكور في الكود) — ولا توحي بأنها منفذة. القيم الحالية لـ Telegram: استئناف الرفع `unsupported` (لا آلية في TDLib لاستئناف إرسال رسالة)، واستئناف التنزيل `conditional` (فـ `DownloadFile` يدعم `offset` لكن TeleManager لا يستخدمه بعد — المهمة 11)، والبثّ `unknown` (غير مختبَر، قاعدة #18)، والحدود `null` (غير معروفة)، و`maxConcurrentTransfers?`.
- `ProviderError` (sealed في `lib/providers/provider_error.dart`): `notInitialized`، `unauthenticated`، `network` (فشل شبكة مؤكد — وليس مهلة؛ المهلة التقنية هي `requestUnresolved`)، `requestUnresolved(method)` (طلب تقني انتهت مهلته ولم تصل نتيجته بعد؛ `code` هو `request_unresolved`، و`method` هو اسم الطريقة التقنية)، `quotaExceeded`، `notFound`، `permissionDenied`، `floodWait(Duration retryAfter)`، `cancelled`، `invalidInput`، `unknown(providerCode, message)`. لا أسرار في الرسائل أبدًا.

دورة الحياة والتزامن والإلغاء والموارد:
- `initialize()` idempotent (لا عميل ثانٍ)؛ أي استدعاء قبلها يرمي `ProviderNotInitialized` (عدا `authStates` و`currentAuthState` و`dispose`).
- `authenticate()` يبدأ التدفق أو يستعيد الجلسة ويُكمل بالحالة النهائية (`AuthAuthenticated` أو `AuthFailed`)؛ الحالات الوسيطة على `authStates`. بلا بيانات اعتماد محفوظة يُكمل `AuthFailed(unauthenticated)` دون رمي. `initialize` و`authenticate` محميتان من التكرار المتزامن (نفس الـFuture للمتزامنين).
- `signOut()` خروج آمن يمسح الجلسة: تستدعي `LogOut` (بمهلة 30 ثانية)، ثم **تنتظر وصول حالة `Closed` على Dart** (مهلة 8 ثوانٍ قابلة للضبط `closeWaitTimeout`)، ثم **تعيد تهيئة الجسر** لإنشاء عميل جديد — فتبقى المصادقة التالية ممكنة دون إعادة تشغيل التطبيق. وهي single-flight: استدعاءان متزامنان يشتركان في **نفس كائن `Future`** (`identical(f1, f2) == true`)؛ وفحص العملية الجارية يأتي قبل حراس disposed/unusable، فلا يستبدل استدعاء جديد `_closedCompleter` الخاص باستدعاء سابق. وإن انتهت مهلة `logOut` أو مهلة `Closed` ترمي الخطأ **ويصبح المزود غير قابل لإعادة الاستخدام** (راية داخلية `_logoutUnresolved`): ترفض `initialize()` و`authenticate()` و`signOut()` و`getAccountCapabilities()` وخطوات الإرسال **قبل إرسال أي طلب** بـ `ProviderUnknown` ذي `providerCode` هو `provider_unusable_after_logout`، ولا يزيل وصول `Closed` المتأخر هذه الراية وحدَه؛ والخلاص حينها `dispose()` + مزوّد جديد. والجسر يرفض `initialize()` بحارس فشل سريع إن كان عميل سابق ما زال مفتوحًا ولم يُؤكَّد إغلاقه. والحالة النهائية غير المصادقة تصل عبر `authStates`.
- `إبطال محاولة `authenticate()` الجارية: عند بدء `signOut()` (بعد فحص الطلب المعلّق، قبل انتظار `logOut`) وعند `dispose()` تُلغى أي محاولة مصادقة جارية: يُزاد جيل المحاولة الداخلي (`_authenticateGeneration`، مستقل عن `_authGeneration` الذي يعدّ تحديثات الحالة لإسقاط نتائج `_onReady` القديمة) وتُكمل أي `_authCompleter` معلّقة بنتيجة إلغاء واضحة ثم تُصفَّر. وتلتقط كل محاولة رقم الجيل عند بدايتها وتفحصه بعد كل `await` (قراءتا بيانات الاعتماد و`setTdlibParameters` وانتظار الحالة الطرفية) وداخل كل مسار `catch` قبل إصدار أي حالة أو إرجاع خطأ — فلا يسمح رد متأخر (Ok أو Error) لمحاولة ملغاة بمواصلة التنفيذ أو إنشاء `_authCompleter` جديد أو إصدار `AuthFailed` قديمة. ونتيجة الإلغاء موحدة: `AuthFailed(ProviderUnknown('authentication_cancelled_by_sign_out'))` لـ signOut و`AuthFailed(ProviderUnknown('provider_disposed'))` لـ dispose، وتُعاد دون `_emit` (فيبقى سجل الحالات على الحالة الحقيقية للمزود: `AuthUnauthenticated` بعد signOut). وبعد إلغاء signOut يبقى المزود قابلًا لإعادة الاستخدام (محاولة `authenticate()` جديدة تبدأ بجيل جديد)؛ وبعد إلغاء dispose يكون المزود منتهيًا. و`_authenticateFuture` يُحرَّر دائمًا عبر `finally` في `authenticate()` لأن `_authenticate()` تعود في كل مسار.
- `authenticate()` ينتظر إدخال المستخدم (هاتف/رمز/2FA/QR) بلا مهلة؛ أما الطلبات التقنية فلها مهلات: `setTdlibParameters` 10 ثوانٍ، وخطوات الإرسال (`setAuthenticationPhoneNumber` و`checkAuthenticationCode` و`checkAuthenticationPassword` و`requestQrCodeAuthentication`) و`logOut` 30 ثانية لكل منها، و`getMyId` 5 ثوانٍ و`close()` 8 ثوانٍ (في الجسر). والمهلة التقنية تُترجم إلى `ProviderRequestUnresolved` (وليست `ProviderNetwork`) — فالمهلة ليست إلغاءً: الطلب الأصلي قد يُكمل متأخرًا، ونتيجته المتأخرة تُهمل (نتيجة الطريقة) أو تُعالَج عبر قناة الحالات (تحديث مصادقة متأخر صحيح يُعالَج عادةً). والجسر يتتبع كل طلب بهوية مستقلة (`_PendingRequest`) ويزيل الإدخال فقط عند وصول الرد (في حينه أو متأخرًا)؛ ويرفض المزوّد إرسال طلب تقني مكررًا بينما طلب سابق من الطريقة نفسها ما زال غير محسوم (`hasPendingRequest`/`isRequestUnresolved`)، ويُسمح بإعادة المحاولة بعد وصول الرد المتأخر. وفي Kotlin يحمي `clientLock` و`clientGeneration` دورة حياة العميل: تُفحص صلاحية الجيل ويُنشر التحديث داخل نفس `synchronized(clientLock)` (فحص + نشر ذريان)، ويُصفَّر مرجع العميل عند وصول `Closed`، فلا يُستخدم عميل أغلقته TDLib أبدًا. ولا طريقة `cancelAuthentication()` خفيفة منفصلة في هذا العقد؛ وإبطال محاولة مصادقة جارية يتم عبر `signOut()` أو `dispose()` (انظر بند الإبطال أعلاه).
- `getAccountCapabilities()` يتطلب مصادقة.
- `dispose()` نهائي وidempotent وآمن في أي وقت؛ يغلق عميل TDLib بعد تأكيد `Closed`؛ بعده لا يُستخدم المزود. ويُبطل أي محاولة `authenticate()` جارية (تعيد `AuthFailed(provider_disposed)`) قبل أول انتظار فيه، فلا يعلّق رد متأخر بعد بدء dispose.
- لا إلغاء في هذا العقد (الإلغاء في `StorageOperations`).

المستهلكون: TM-Transfer وطبقة التطبيق (وميزة المصادقة لخطوات Telegram).

### `TdlibDatabaseKeyStore` — مفتاح تشفير قاعدة TDLib (دائم)
الملف: `lib/providers/telegram/tdlib_database_key_store.dart`. التنفيذ: `SecureTdlibDatabaseKeyStore` (عبر `flutter_secure_storage`، مدعوم بـ Android Keystore).

المسؤولية: تخزين مفتاح تشفير قاعدة بيانات TDLib (32 بايت، AES-256) واسترجاعه بأمان. المفتاح بايتات من البداية إلى النهاية؛ لا يُسجَّل ولا يُعرض ولا يظهر في أي خطأ أو تشخيص (ولا حتى بصيغة Base64).

التواقيع (Dart):
```dart
abstract interface class TdlibDatabaseKeyStore {
  Future<Uint8List?> readKey();
  Future<Uint8List> createKey();
  Future<void> clearKey();
  Future<Uint8List> getOrCreateKey({required bool databaseExists});
}
```

القواعد (ملزمة):
- يُولَّد المفتاح **فقط** عند عدم وجود قاعدة بيانات (`databaseExists == false`). وقاعدة موجودة دون مفتاح مخزَّن = فشل صريح `ProviderUnknown('tdlib_database_key_missing')`، ولا توليد صامت أبدًا (لأن توليد مفتاح جديد فوق قاعدة موجودة يُيتم الجلسة).
- مفتاح مخزَّن تالف (Base64 خاطئ أو طول ≠ 32 بايتًا) = `ProviderUnknown('tdlib_database_key_corrupt')` عند وجود قاعدة؛ وعند عدم وجود قاعدة يُمسح التالف ويُولَّد مفتاح جديد.
- فشل `flutter_secure_storage` (قراءة/كتابة/حذف) = `ProviderUnknown('tdlib_database_key_unreadable')`، ولا بديل صامت بمفتاح فارغ أبدًا.
- المتصلون المتزامنون يشتركون في عملية واحدة جارية (single-flight، نفس نمط `_authenticateFuture`)، فلا يُولَّد المفتاح ولا يُحفظ مرتين. والفحص والقراءة والتوليد والحفظ كلها داخل العملية المُسلسلة. والذاكرة المؤقتة داخل الذاكرة تُمسح عند `clearKey()`.
- `clearKey()` يُستخدم فقط مع حذف مجلد قاعدة البيانات معًا (إجراء "إعادة ضبط جلسة الاختبار" في الـ Harness)؛ ولا يُحذف المفتاح وحده أبدًا.

المستهلك: `TelegramProvider._authenticate()` (يقرأ المفتاح ويمرره إلى `setTdlibParameters` قبل إرسال المعاملات؛ فخطأ المفتاح يُرجع `AuthFailed` مثل أي خطأ معاملات).

### `TdlibBridge` — إضافات (دائمة + مؤقتة)
الملف: `lib/providers/telegram/tdlib_method_channel.dart` (Dart) و`android/native/tdlib_bridge/TdlibBridge.kt` (Kotlin).

**دائم:**
- `setTdlibParameters` يكتسب معاملًا مطلوبًا `databaseEncryptionKey` (Uint8List، 32 بايتًا، يُرسل ثنائيًا ولا يُسجَّل). والجسر يرفض `bridge_invalid_args` إن كان المفتاح غائبًا أو طوله ≠ 32، ويمرره إلى `TdApi.SetTdlibParameters` بدل `ByteArray(0)` (القاعدة غير المشفرة سابقًا). ونفس المفتاح يجب تمريره في كل تشغيل، وإلا لم تُفتح القاعدة.
- `getNoBackupFilesDirectory()` يُرجع مسار `Context.getNoBackupFilesDir()` (مستثنًى من Auto Backup بالتعريف). وقاعدة TDLib تعيش في `<no-backup>/tdlib` (والملفات في `<no-backup>/tdlib/files`)، فلا يمكن لنسخة احتياطية استعادة قاعدة دون مفتاحها (Keystore لا يُنسخ احتياطيًا معها). والجسر يخزّن `applicationContext` في `onAttachedToEngine` لهذا الغرض.

**مؤقت (اختبار فقط، يُحذف مع الـ Harness):**
- `setTestReplyDelay(method, delayMs)` و`clearTestReplyDelays()` و`getTestSendCounts()` — طرق قناة debug فقط (`BuildConfig.DEBUG`؛ وفي release تُرجع `notImplemented`). وهي **ليست** جزءًا من واجهة `TdlibBridge` بل من التطبيق الخرساني `MethodChannelTdlibBridge`، ويستدعيها الـ Harness فقط عبر `HarnessTestHooks`.
- آلية التأخير: الطلب يُرسل إلى TDLib فورًا؛ ويُؤخَّر **تسليم** `MethodChannel.Result` إلى Dart فقط (لـ `SetTdlibParameters` و`LogOut` فقط). والرد محفوظ في `PendingReply` (تسليم مرة واحدة عبر `AtomicBoolean` + حارس `detached`/`channel != null` + `try/catch`، وعلى الخيط الرئيسي). ومهلة Dart لا تُسقط الرد (يُسلَّم متأخرًا ويحرّر الإدخال المعلق)؛ والفصل وحده يُسقطه. و`onDetachedFromEngine` بترتيب دقيق: إلغاء الاستدعاءات المؤجلة ← علامة `detached` ← إغلاق العميل ← إيقاف المنفذ ← `channel = null`. وقناة تحديثات المصادقة (`onAuthorizationState`) لا تُمسّ أبدًا (فـ `Closed` والحالات الأخرى فورية).

### `StorageOperations` — يملكه TM-Cloud (معرّف في المهمة 05، يُنفَّذ في المهمة 06)
الملف: `lib/providers/storage_operations.dart`.

المسؤولية: عمليات النقل والتخزين (رفع/تنزيل/حذف/معلومات/إلغاء). فُصل عن `StorageProvider` حتى لا تشحن المهمة 05 دوالًا غير منفذة أو نتائج وهمية؛ `TelegramProvider` يضيف هذا العقد في المهمة 06.

التواقيع (Dart):
```dart
abstract interface class StorageOperations {
  Future<UploadResult> uploadFile(UploadRequest request, ProgressCallback onProgress);
  Future<DownloadResult> downloadFile(DownloadRequest request, ProgressCallback onProgress);
  Future<void> deleteFile(StorageObjectId id);
  Future<RemoteFileInfo> getFileInfo(StorageObjectId id);
  Future<void> cancelOperation(OperationId id);
}
```

نماذج البيانات (في `lib/providers/transfer_models.dart` و`lib/providers/storage_object.dart`):
- `FileId` (UUID داخلي من TM-Core، وليس أي مرجع Telegram أبدًا) و`StorageObjectId` (معتم يصنعه المزود) و`StorageObject` (حسب المخطط §6.4: `id` و`fileId` و`provider` و`accountId` و`remoteUniqueId?` و`remoteStatus`؛ مراجع Telegram الخاصة `chat_id`/`message_id`/`tdlib_file_id` في `TelegramStorageReferences` داخل حزمة المزود فقط).
- `OperationId` (UUID لكل عملية)، و`TransferProgress` (`transferredBytes` و`totalBytes?`)، و`ProgressCallback`.
- `UploadRequest` (`fileId` و`localPath` و`fileName` و`fileSizeBytes` و`checksumSha256?` المحسوبة من المتصل) و`DownloadRequest` و`UploadResult` (يحمل `StorageObject` الذي يجب حفظه قبل إعلان الاكتمال) و`DownloadResult` (`checksumVerified`) و`RemoteFileInfo`.

القواعد: لا تُعلن عملية `Completed` قبل تأكيد المزود وحفظ المرجع؛ الإلغاء best-effort؛ الحذف السحابي ليس أثرًا جانبيًا لمسح Cache.

### عقود TM-Core
المسؤولية: عمليات VFS مثل إنشاء المجلدات وإعادة التسمية والنقل والحذف المنطقي والبحث والتصنيف. يجب أن تكون مستقلة عن Telegram وتستخدم UUID داخليًا. لم تحدد التواقيع بعد.

### عقود TM-Transfer
المسؤولية: إنشاء عملية دائمة، متابعة حالتها وتقدمها، الإلغاء والإيقاف/الاستئناف عند الدعم، والاستعادة بعد إعادة تشغيل التطبيق. لم تحدد التواقيع بعد.

### عقود البيانات
المسؤولية: معاملات واستعلامات SQLite/Drift ومهاجرات للمخطط. أسماء الجداول والحقول الأولية في `DATABASE.md` مواصفات وليست schema منفذة.

### عقود TM-Backup وTM-Sync وTM-Cache
المسؤوليات: النسخ المشفر والاستعادة؛ سجل التغييرات وتعارضاته؛ وسياسة Cache. لم تنشأ واجهاتها أو مخطط التشفير/التعارض التنفيذي بعد.

### Test Harness — مؤقت (Task 05، D1–D5)
الملفات: `lib/features/developer/harness/` (الـ Controller والشاشة وQR ونموذج بيانات الاعتماد والسجل/التنقية وخطافات الاختبار ونقطة الدخول) + نقطة دخول `kDebugMode` في `lib/main.dart` + اعتماد `qr_flutter` في `pubspec.yaml`.

المسؤولية: شاشة تطوير مؤقتة تختبر `TelegramProvider` وطبقة TDLib فعليًا على جهاز Android (المصادقة وإعادة المصادقة والخروج وإغلاق العميل وإنشاء مزوّد جديد)، باستخدام الطبقات الحقيقية (لا Fake على الجهاز). تُحذف كاملةً بعد D1–D5 (مع آلية التأخير وعدّاد الإرسال ونقطة الدخول و`qr_flutter` إن لم تستخدمه الواجهة النهائية). وما يبقى دائمًا: مفتاح تشفير القاعدة ومسار `no_backup` (انظر `TdlibDatabaseKeyStore` و`TdlibBridge` أعلاه).

العقد (Dart):
```dart
final class HarnessController extends ChangeNotifier {
  static Future<HarnessController> create(); // مزوّد حقيقي + مسارات no-backup
  Future<void> initialize();
  Future<void> authenticate();
  Future<void> signOut();
  Future<void> disposeProvider();
  Future<void> createNewProvider();
  Future<void> resetTestSession(); // حذف القاعدة + المفتاح معًا، متحقق منه
  Future<void> setReplyDelay(String method, int delayMs); // debug فقط
  Future<void> clearReplyDelays();
  Future<void> saveCredentials(int apiId, String apiHash);
  // الحالة: authState وmyId (على الشاشة فقط) وlastError وkeyStatus
  // وsendCounts ومؤشرات pending/unresolved وeventLog (منقّى).
}
```

القواعد (ملزمة):
- لا Fake على الجهاز: المزوّد الحقيقي + الجسر الحقيقي + TDLib الحقيقية.
- لا أسرار في السجل أو التقارير أبدًا: لا بيانات اعتماد ولا أرقام هواتف ولا رموز ولا كلمات مرور ولا روابط QR ولا مسارات قواعد ولا مفاتيح (فقط "المفتاح موجود: نعم/لا"). و`my_id` على الشاشة فقط؛ وفي السجل "مطابق للمتوقع: نعم/لا" فقط. والرابط يُعرض كصورة QR فقط (جهاز ثانٍ يمسحه) ولا يُعرض كنص ولا يُسجَّل.
- `resetTestSession()` يرفض عند وجود طلب معلّق أو غير محسوم (يجب وصول الرد المتأخر وتحرير الإدخال أولًا)؛ ثم `dispose()`؛ ثم حذف مجلد القاعدة **ومسح المفتاح معًا**؛ ثم التحقق من كليهما (المجلد ذهب + `readKey() == null`) قبل إعلان النجاح؛ ولا يُنشئ مزوّدًا جديدًا (يُنشأ صراحةً بعدها). وبيانات الاعتماد تبقى. وSpike لا يُمسّ أبدًا (حزمة ومسار بيانات مختلفان).
- رابط `tg://` خيار تجريبي غير مضمون ولا يُستخدم في D2؛ والجهاز الثاني هو الطريقة المعتمدة لمسح QR.
- التأخير debug فقط (`BuildConfig.DEBUG`)؛ وD1: `setTdlibParameters` 15000ms؛ وD3: `logOut` 35000ms؛ ويُمسح قبل D2/D4/D5.

## نموذج بيانات وحدود دائمة
- كل ملف ومجلد يحمل UUID داخليًا ثابتًا.
- مرجع المزود كيان منفصل يمكن تحديثه، ويمكن أن يمتلك الملف أكثر من Storage Object.
- `message_id` أو `tdlib_file_id` ليس المفتاح الأساسي لملف TeleManager.
- عمليات النقل طويلة الأمد غير متزامنة وسجلاتها دائمة، ولا تعلن Completed قبل تأكيد التخزين وحفظ المرجع.
