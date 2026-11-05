# XSign v10

استبدل .github/workflows/XSign_AppStore_Experience.yml على X-SIGN/main.
افتح التشغيل الجديد XSign Native Update v10، ثم نزّل XSign-AppStore-IPA بعد نجاح البناء.
يحفظ الأكشن ملفات Swift والمزامن على main بعد النجاح، دون تغيير workflows أو فرض الدفع.

المصادر الأصلية المستقلة:
- https://raw.githubusercontent.com/ipa-black/IPABLACK/main/repo.json
- https://appiraq.com/source.php?action=getAll

مزامن IPAOMTK العام: Tools/Sync_Live_Sources.py.
مصدره https://ipaomtk.com/wp-json/wp/v2/posts، ويحوّل WordPress إلى فهرس XSign.
ينشر على https://raw.githubusercontent.com/ipa-black/X-SIGN/main/public/sources/ipaomtk.json
وينشر حالة الجلب في public/sources/status.json. تصبح الروابط متاحة بعد أول حفظ ناجح.
التحديث مجدول كل ساعة تقريبًا، والتطبيق يفحص التحديثات كل خمس دقائق وهو نشط.

سورسا han.json وgetAll متداخلان، فيُستخدم getAll مرة واحدة. أعاد وقت الفحص 74 سجلًا.
قائمة soon.json ذات 1500 صف داخل IPA ليست مصدرًا عامًا حيًا؛ رابطها العام أعاد 404.
المزامن لا يستخدم مفاتيح التطبيق المرجعي، ولا يختلق بندلًا عندما لا ينشره المزود.

كل اختبارات Swift تمرر macOS SDK صراحةً. يحافظ التحديث على آخر بيانات سليمة عند انقطاع المزود.
بناء Xcode والتثبيت على iPhone مطلوبان؛ لم ينجز هذا التحديث الدومين أو iOS 14.

أُزيل store-api من المصادر بعد مقارنة قائمته بالمصادر الجديدة. يحذف البناء مورديه القديمين ويضمّن كتالوج IPAOMTK الحي كاملًا ومعاينة صغيرة. الإعدادات القديمة لا تعيده.
