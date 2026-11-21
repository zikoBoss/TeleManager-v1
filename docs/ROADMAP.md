# خارطة طريق TeleManager

لا تنتقل إلى مرحلة تالية لمجرد مرور الوقت؛ الانتقال بعد اجتياز معيار المرحلة. هذه المراحل تحترم مخطط المستخدم وتسلسله ولا تعني إنجازها.

| المرحلة | النتيجة | بوابة الانتقال |
|---|---|---|
| 1. التأسيس | المستودع، المخطط، PROJECT_RULES، هيكل المجلدات، واجهات معمارية موثقة | توثيق الأدوات والقرارات المؤجلة؛ لا تدّع scaffold قابلًا للبناء قبل Flutter check |
| 2. Flutter/Android | مشروع Flutter وKotlin مهيأ | بناء Android تجريبي ونتيجة `flutter analyze`/الاختبارات موثقة |
| 3. TDLib spike | قرار موثق حول حزمة/مصدر TDLib وABI والترخيص وبناء/تشغيل Android مستقل | إثبات العميل وتدفق تحديثاته وإدارة الأخطاء + مصادقة واستعادة جلسة (في Spike مستقل). ونقل الملف التجريبي ليس شرطًا لهذه البوابة — بل اختبار المرحلة 5 (Task 06) |
| 4. المصادقة والقناة | مصادقة و2FA واستعادة جلسة وقناة تخزين بعد موافقة | اختبارات حساب فعلية، عدم تسريب أسرار وعدم تكرار إنشاء القناة |
| 5. TM-Cloud والعمليات | StorageProvider وTelegramProvider ورفع/تنزيل | تأكيد الخادم وحفظ مرجع التخزين، تقدم وإلغاء وأخطاء واضحة، ونقل ملف تجريبي (الاختبار الذي لم يحدث في الـ Spike) |
| 6. Drift وVFS | migrations وجداول الملفات/المجلدات/المراجع ونظام ملفات افتراضي | نقل داخل VFS دون إعادة رفع ومعاملات وسلوك حذف آمن |
| 7. التصنيف والبحث | MIME/signature وتصنيفات وبحث/فرز | نتائج موثقة وقياس أداء على 10,000 سجل مستهدف |
| 8. Transfer Queue | سجل دائم واستعادة/إلغاء/إعادة محاولة | إعادة فتح التطبيق دون تكرار غير مقصود؛ استئناف فقط حين تدعمه TDLib |
| 9. الواجهة | الشاشات وExplorer وTransfer Manager | ربط الواجهة بطبقة الاستخدام دون SQL أو منطق Telegram داخل Widgets |
| 10. Cache/Preview | سياسة سعة ومعاينة وتنزيل/streaming مثبت | حذف Cache يبقي Cloud؛ عدم الادعاء بstreaming بلا اختبار TDLib |
| 11. Backup/Restore | snapshot مشفر ومتحقق ومهاجرات | استعادة ناجحة ورفض نسخة تالفة ومفتاح قابل للاستعادة |
| 12. Sync | Change Log وdevice IDs وidempotency وحل التعارض | مزامنة على جهازين أو أكثر وكشف التعارض دون حذف صامت |
| 13. الاختبارات والإصدار | unit/integration/widget/أمان/أداء ثم إعداد APK | لا APK موصوف بالمستقر قبل اجتياز معايير القبول الفعلية |

## حدود الإصدار التجريبي الأول
وظائف MVP في المخطط: دخول Telegram واستعادة الجلسة؛ إنشاء قناة التخزين بعد الموافقة؛ اختيار ملف محلي ورفعه؛ حفظ metadata ومرجع الرسالة؛ عرضه في قائمة TeleManager؛ تنزيله والتحقق منه؛ حذف Cache دون حذف الملف السحابي. يلي ذلك إضافة المجلدات الافتراضية والتصنيف والبحث.

مزايا مستقبلية لا تبدأ قبل استقرار VFS وTDLib وTransfer Queue: File Versioning، Duplicate Detection، Archive Preview، Batch Upload/Download، File Integrity Verification، Custom Tags، Favorites، Recently Opened، Offline Favorites، Advanced Filters، Client-side File Encryption، Import/Export Folder Tree، Multiple Telegram Accounts، ومزودات WebDAV/Google Drive/Custom Server.
