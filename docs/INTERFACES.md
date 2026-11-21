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
- `authenticate()` ينتظر إدخال المستخدم (هاتف/رمز/2FA/QR) بلا مهلة؛ أما الطلبات التقنية فلها مهلات: `setTdlibParameters` 10 ثوانٍ، وخطوات الإرسال (`setAuthenticationPhoneNumber` و`checkAuthenticationCode` و`checkAuthenticationPassword` و`requestQrCodeAuthentication`) و`logOut` 30 ثانية لكل منها، و`getMyId` 5 ثوانٍ و`close()` 8 ثوانٍ (في الجسر). والمهلة التقنية تُترجم إلى `ProviderRequestUnresolved` (وليست `ProviderNetwork`) — فالمهلة ليست إلغاءً: الطلب الأصلي قد يُكمل متأخرًا، ونتيجته المتأخرة تُهمل (نتيجة الطريقة) أو تُعالَج عبر قناة الحالات (تحديث مصادقة متأخر صحيح يُعالَج عادةً). والجسر يتتبع كل طلب بهوية مستقلة (`_PendingRequest`) ويزيل الإدخال فقط عند وصول الرد (في حينه أو متأخرًا)؛ ويرفض المزوّد إرسال طلب تقني مكررًا بينما طلب سابق من الطريقة نفسها ما زال غير محسوم (`hasPendingRequest`/`isRequestUnresolved`)، ويُسمح بإعادة المحاولة بعد وصول الرد المتأخر. وفي Kotlin يحمي `clientLock` و`clientGeneration` دورة حياة العميل: تُفحص صلاحية الجيل ويُنشر التحديث داخل نفس `synchronized(clientLock)` (فحص + نشر ذريان)، ويُصفَّر مرجع العميل عند وصول `Closed`، فلا يُستخدم عميل أغلقته TDLib أبدًا. ولا طريقة إلغاء خفيفة للمصادقة في هذا العقد؛ والإلغاء هو `dispose()` + مزوّد جديد.
- `getAccountCapabilities()` يتطلب مصادقة.
- `dispose()` نهائي وidempotent وآمن في أي وقت؛ يغلق عميل TDLib بعد تأكيد `Closed`؛ بعده لا يُستخدم المزود.
- لا إلغاء في هذا العقد (الإلغاء في `StorageOperations`).

المستهلكون: TM-Transfer وطبقة التطبيق (وميزة المصادقة لخطوات Telegram).

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

## نموذج بيانات وحدود دائمة
- كل ملف ومجلد يحمل UUID داخليًا ثابتًا.
- مرجع المزود كيان منفصل يمكن تحديثه، ويمكن أن يمتلك الملف أكثر من Storage Object.
- `message_id` أو `tdlib_file_id` ليس المفتاح الأساسي لملف TeleManager.
- عمليات النقل طويلة الأمد غير متزامنة وسجلاتها دائمة، ولا تعلن Completed قبل تأكيد التخزين وحفظ المرجع.
