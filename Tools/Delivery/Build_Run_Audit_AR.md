# مراجعة تشغيلات XSign — 7 نوفمبر 2026

المستودع العام: https://github.com/ipablack/X-SIGN . آخر commit عند الفحص 627c3752cfbc474b3a84932b1f2c4bf107ee2b3c. روجعت كل التشغيلات العامة التي أعادها GitHub وعددها 42: 12 failure و1 cancelled و22 skipped و7 success. فُحصت مهام جميع التشغيلات الفاشلة/الملغاة وAnnotations، وصفحات Workflow التي لم تبدأ مهام، وسجل Xcode الكامل وفحوص Swift من XSign-native-logs في التشغيل الأخير.

## التشغيل الأخير 42290681355

https://github.com/ipablack/X-SIGN/actions/runs/42290681355

اختيار Xcode 26 نجح. توقفت ترجمة Feather عند 10 أخطاء في CertificatesView وSigningAlternativeIconView وSourcesAddView وResetView وSettingsDonationCellView وExpandableText. التفاصيل والتصحيح في XSign_Unified_Guide_AR.md. أصغر حل يحافظ على iOS 15 هو نقل شروط أزرار الشريط داخل ToolbarItem، واستخدام URL.path كخاصية وFont.bold وإجراء ضغط دون إحداثيات.

وسعت اختبارات التوافق المبكرة لتلتقط هذه الحالات بدلاً من الاقتصار على الرموز الحديثة الصريحة. لا حاجة لتغيير العامل أو رفع الحد إلى iOS 16/17، ولا توجد رسالة تعطل شهادة أو خدمة manifest في هذا الإخفاق. اختبارات Swift اللاحقة للبناء لم تبدأ في هذا التشغيل، فلا تسجل كاختبارات فاشلة.

## خطأ التشغيل السابق 42278275567

https://github.com/ipablack/X-SIGN/actions/runs/42278275567

- نجح preflight، وخُصص عامل macos-15-intel بالفعل. نجحت اختبارات Swift للكتالوج والشهادات والتخزين والنقل والتحديث والتوقيع المحلي والـOTA وZIP.
- فشل Build and verify the iOS application: `FileManager+shortcuts.swift:52` استعمل URL.documentsDirectory التي تبدأ عند iOS 16، و`View+compatSearchScopes.swift:20` استعمل searchScopes في مسار iOS 15. انتهى xcodebuild بخطأ 65 وmake بخطأ 2.
- أصلح الوصول إلى Documents بواجهة FileManager الأقدم، وأصبح فرع searchScopes محروساً بـiOS 16، مع Picker بديل يعمل في iOS 15.
- كشف التدقيق مواضع إضافية تحتاج التوافق: 33 زر systemImage، واستضافة خلايا SwiftUI والعناوين، وقائمة عنوان التنقل، والتصحيح التلقائي وأشكال الزوايا وأوزان الخطوط. تتضمن النسخة بدائلها؛ هذا استباق لأخطاء لاحقة، وليس ادعاء أنها كلها ظهرت في السجل السابق.
- يختار عامل macOS برنامج Xcode 26 مستقراً مثبتاً مع SDK مناسب، عوض الافتراضي 16.4 الذي لا يعرف واجهات iOS 26 الموجودة في المكتبة. يبقى deployment target على 15.0.
- يعرض المتجر تفاصيل التطبيق على iOS 15 و16؛ صحح الفرز التنازلي للأسماء واتجاه التواريخ، وحُمي اختيار الصفوف أثناء التحديث من تجاوز الحدود. يعاد استعمال مستضيف الخلية وفك ارتباطه عند خروجه من النافذة.
- أدوات Actions الفعالة تستخدم Node 24 صراحة؛ تحذير Node 20 كان مستقلاً عن خطأ البناء. يحفظ xcresult مع السجلات، وتترجم الواجهة قبل الفحوص الطويلة لتظهر مشاكلها أسرع.

## الإخفاقات التاريخية

النتيجة المسجلة لتشغيل قديم لا تتغير عند إصلاح الكود. source-setup skipped في التشغيل الأخير نتيجة اعتماده على build، ولا يثبت خطأ في توكن السورس.

الـWorkflow الموحد الحالي دون 500 KB ومقسّم ضمن حد run؛ محرك التثبيت لا يشترط خدمة Firebase القديمة. main.yml وXSign_Internal_Signing_Server.yml المحذوفان غير موجودين في آخر commit العام؛ خمسة Workflows قديمة أخرى موجودة بحالة disabled_manually. لا يعيد المثبت الملفات المحذوفة. التشغيلات skipped ليست أخطاء بناء، والتشغيلات القديمة الناجحة لا تثبت نجاح كود 1.0 الحالي.

## الجرد الكامل

| التشغيل | Workflow | النتيجة | الملاحظة |
|---|---|---|---|
| [42290681355](https://github.com/ipablack/X-SIGN/actions/runs/42290681355) | XSign Unified 1.0 — App, Studio and IPA Publisher | failure | عشرة أخطاء توافق iOS في ستة ملفات واجهة؛ نجح اختيار Xcode 26 |
| [42278275567](https://github.com/ipablack/X-SIGN/actions/runs/42278275567) | XSign Unified 1.0 — App, Studio and IPA Publisher | failure | نجحت preflight وفحوص Swift؛ توقف Xcode عند API تتطلب iOS 16 |
| [42270819790](https://github.com/ipablack/X-SIGN/actions/runs/42270819790) | XSign Unified 1.0 — App, Studio and IPA Publisher | failure | عدم تخصيص عامل macOS ARM64؛ job ملغى قبل أية خطوة |
| [42270208030](https://github.com/ipablack/X-SIGN/actions/runs/42270208030) | Build and Release X-SIGN | cancelled | إلغاء من المالك مع رسائل قيود سعة ARM64 |
| [42270205629](https://github.com/ipablack/X-SIGN/actions/runs/42270205629) | .github/workflows/XSign_Internal_Signing_Server.yml | failure | Workflow أكبر من حد 500 KB؛ لم تبدأ مهمة |
| [42266673070](https://github.com/ipablack/X-SIGN/actions/runs/42266673070) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42259224883](https://github.com/ipablack/X-SIGN/actions/runs/42259224883) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42249050816](https://github.com/ipablack/X-SIGN/actions/runs/42249050816) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42239640008](https://github.com/ipablack/X-SIGN/actions/runs/42239640008) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42225685198](https://github.com/ipablack/X-SIGN/actions/runs/42225685198) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42214884032](https://github.com/ipablack/X-SIGN/actions/runs/42214884032) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42203868821](https://github.com/ipablack/X-SIGN/actions/runs/42203868821) | XSign Controlled Store and Verified Updates — iOS 15+ | failure | اشتراط خدمة manifest القديمة أوقف preflight |
| [42201863743](https://github.com/ipablack/X-SIGN/actions/runs/42201863743) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42194766205](https://github.com/ipablack/X-SIGN/actions/runs/42194766205) | Build and Release X-SIGN | success | نجاح تاريخي للملف والالتزام الخاصين به |
| [42194764378](https://github.com/ipablack/X-SIGN/actions/runs/42194764378) | .github/workflows/XSign_Internal_Signing_Server.yml | failure | Workflow أكبر من حد 500 KB؛ لم تبدأ مهمة |
| [42187644231](https://github.com/ipablack/X-SIGN/actions/runs/42187644231) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42173728707](https://github.com/ipablack/X-SIGN/actions/runs/42173728707) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42167494650](https://github.com/ipablack/X-SIGN/actions/runs/42167494650) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42161177332](https://github.com/ipablack/X-SIGN/actions/runs/42161177332) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42154647477](https://github.com/ipablack/X-SIGN/actions/runs/42154647477) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42144249490](https://github.com/ipablack/X-SIGN/actions/runs/42144249490) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42141825964](https://github.com/ipablack/X-SIGN/actions/runs/42141825964) | Build and Release X-SIGN | success | نجاح تاريخي للملف والالتزام الخاصين به |
| [42141824184](https://github.com/ipablack/X-SIGN/actions/runs/42141824184) | .github/workflows/XSign_Internal_Signing_Server.yml | failure | Workflow أكبر من حد 500 KB؛ لم تبدأ مهمة |
| [42141481642](https://github.com/ipablack/X-SIGN/actions/runs/42141481642) | Build and Release X-SIGN | success | نجاح تاريخي للملف والالتزام الخاصين به |
| [42133181545](https://github.com/ipablack/X-SIGN/actions/runs/42133181545) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42126404966](https://github.com/ipablack/X-SIGN/actions/runs/42126404966) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42117951632](https://github.com/ipablack/X-SIGN/actions/runs/42117951632) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42109588373](https://github.com/ipablack/X-SIGN/actions/runs/42109588373) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42100705858](https://github.com/ipablack/X-SIGN/actions/runs/42100705858) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42092231686](https://github.com/ipablack/X-SIGN/actions/runs/42092231686) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42080119339](https://github.com/ipablack/X-SIGN/actions/runs/42080119339) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42063755548](https://github.com/ipablack/X-SIGN/actions/runs/42063755548) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42059807981](https://github.com/ipablack/X-SIGN/actions/runs/42059807981) | XSign Secure Local Signing | failure | عدم تخصيص عامل ARM64 قبل أي خطوة |
| [42059746766](https://github.com/ipablack/X-SIGN/actions/runs/42059746766) | Build and Release X-SIGN | failure | عدم تخصيص عامل ARM64 قبل أي خطوة |
| [42059655003](https://github.com/ipablack/X-SIGN/actions/runs/42059655003) | Build and Release X-SIGN | failure | عدم تخصيص عامل ARM64 قبل أي خطوة |
| [42045360671](https://github.com/ipablack/X-SIGN/actions/runs/42045360671) | XSign Native Update v12 | skipped | لم يبدأ بناء؛ لا يُصنف كخطأ |
| [42032029436](https://github.com/ipablack/X-SIGN/actions/runs/42032029436) | XSign Local Signing and Installation | success | نجاح تاريخي للملف والالتزام الخاصين به |
| [42031952549](https://github.com/ipablack/X-SIGN/actions/runs/42031952549) | Build and Release X-SIGN | success | نجاح تاريخي للملف والالتزام الخاصين به |
| [42028975837](https://github.com/ipablack/X-SIGN/actions/runs/42028975837) | Build and Release X-SIGN | success | نجاح تاريخي للملف والالتزام الخاصين به |
| [42026311620](https://github.com/ipablack/X-SIGN/actions/runs/42026311620) | Restore Original XSign Into Repository Root | success | نجاح تاريخي للملف والالتزام الخاصين به |
| [42026255117](https://github.com/ipablack/X-SIGN/actions/runs/42026255117) | .github/workflows/main.yml | failure | main.yml غير صالح: Unexpected value عند السطر الأول |
| [42026205585](https://github.com/ipablack/X-SIGN/actions/runs/42026205585) | .github/workflows/main.yml | failure | main.yml غير صالح: Unexpected value عند السطر الأول |

## نطاق التحقق بعد التصحيح

نجحت فحوص اللوحة وعددها 49، واختبارات إعداد البيئة والتوافق ودمج السورس ودمج Workflows، وتُختبر الحزمة على مراجع التطبيق السابقة وعلى مستودع جديد قبل تسليمها. فحص صياغة Swift لا يساوي فحص أنواعها في SDK. لا يتوفر Xcode أو iPhone محلياً، لذلك نجاح الترجمة الكاملة بعد التصحيح والتثبيت على جهاز لم يثبتا بعد. شغّل Workflow جديداً من commit الذي يضم YML المحدّث؛ Re-run للتشغيل القديم يعيد الملف القديم.
