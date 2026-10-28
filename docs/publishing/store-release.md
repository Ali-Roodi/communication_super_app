# انتشار در فروشگاه‌ها — بازار و مایکت

> **این فایل زنده است.** هر تغییری در وضعیت انتشار (حساب ساخته شد، مجوزی حذف شد،
> نسخه‌ای منتشر شد، بازبینی رد شد) باید در همان commit اینجا هم ثبت شود. هدف این است
> که با باز کردن همین فایل بشود فهمید «الان کجای کار هستیم» بدون بازخوانی تاریخچه.

**آخرین بروزرسانی:** ۱۴۰۵/۰۷/۲۵ — build نهایی با گواهی عضو (`e0e7994`): APK فروشگاهی versionCode ۱۶۵ و APK سازمانی ۲۰۰۰۰۰۰۱۶۵، هر دو از `release_build.sh` با همهٔ بررسی‌ها. هنوز هیچ‌چیز submit نشده.

---

## وضعیت فعلی

| مرحله | وضعیت |
|---|---|
| بررسی فنی build | ✅ انجام شد |
| اقدامات پیش از submission | 🟡 در جریان — ۴ از ۶ انجام شد |
| حساب پیشخان بازار | ⬜ ساخته نشده |
| حساب مایکت | ⬜ ساخته نشده |
| اولین submission بازار | ⬜ — |
| اولین submission مایکت | ⬜ — |
| CI/CD انتشار | ⬜ نوشته نشده (طرحش پایین آماده است) |

**نسخه‌ی منتشرشده:** هنوز هیچ.

**آخرین versionCode ساخته‌شده:** ۱۶۵ (`app-commercial-release.apk`، ۱۴۰۵/۰۷/۲۵، commit `e0e7994`) — ساخته شده، هنوز به
فروشگاه نرفته. اولین upload باید عددی بزرگ‌تر یا مساوی همین داشته باشد. هر build ای که به فروشگاه می‌رود باید
در جدول تاریخچه‌ی پایین ثبت شود. (گوشی‌های آزمون نسخهٔ آزمایشی ۱۶۶ با مرجع توسعه دارند؛ نسخهٔ فروشگاهی روی آن‌ها
فقط بعد از حذف برنامه نصب می‌شود.)

---

## آنچه در build فعلی بررسی شد و درست است

نیازی به تغییر ندارند — چند موردشان دقیقاً همان چیزهایی‌اند که معمولاً باعث reject می‌شوند:

- **`applicationId = ir.hamrasan.app`** — پیشوند `com.example` سیگنال منفی است.
  `namespace` که هنوز `com.example.communication_super_app` مانده اهمیتی ندارد؛ فروشگاه
  فقط `applicationId` را می‌بیند. (دلیل جدا ماندنشان در `android/app/build.gradle.kts` توضیح داده شده.)
- **امضای release** — `enableV1Signing=false`، V2 و V3 روشن. V3 یعنی امکان **key rotation** در آینده.
- **`isMinifyEnabled` + `isShrinkResources`** با keep-ruleهای اختصاصی.
- **`allowBackup=false`** + `dataExtractionRules` — برای اپی که کل mailbox را در SQLite نگه می‌دارد
  این یک برگ برنده در بخش privacy است.
- **Crash reporting** پیش‌فرض خاموش، بدون DSN چیزی ارسال نمی‌شود، و هر رشته‌ی ≥۴ رقم redact می‌شود.
- **keystore داخل repo نیست** — `key.properties` و `*.jks` هر دو gitignore شده‌اند.

---

## اقدامات

### ✅ ۱. حذف `RECORD_AUDIO` — انجام شد (۱۴۰۵/۰۶/۱۸)

اعلام شده بود ولی grep روی `lib/` و `android/app/src/main` هیچ ارجاعی به `MediaRecorder` /
`AudioRecord` پیدا نکرد، و هیچ‌کدام از پلاگین‌های `pubspec` هم صوتی نیستند.

خط از manifest حذف شد و **جای آن یک کامنت نشست** که توضیح می‌دهد چرا عمداً غایب است — تا کسی
دوباره برای فیچری که هنوز وجود ندارد اضافه‌اش نکند.

### ✅ ۲. صفحه‌ی privacy policy با URL عمومی — انجام شد (۱۴۰۵/۰۶/۲۴)

فیلد اجباری فرم انتشار هر دو فروشگاه. بدون آن اصلاً نمی‌شود submit کرد.

**متن لازم (چهار جمله):** داده‌ها فقط روی دستگاه در SQLite ذخیره می‌شوند · هیچ پیام یا مخاطبی
به سروری ارسال نمی‌شود · backup سیستمی غیرفعال است · گزارش خطا پیش‌فرض خاموش و بدون محتوای پیام است.

**نیمه‌ی اول — انجام شد (۱۴۰۵/۰۶/۲۴):** متن به‌صورت صفحه‌ی داخل برنامه نوشته شد —
`PrivacyPolicyPage` (`lib/features/settings/screens/privacy_policy_page.dart`)، از
تنظیمات → «درباره برنامه» → «حریم خصوصی و دسترسی‌ها». **متن مرجع privacy policy همین
صفحه است**؛ نسخه‌ی وب باید از روی آن نوشته شود، نه برعکس، تا چیزی که بازبین فروشگاه می‌خواند
و چیزی که کاربر می‌خواند یکی باشد.

ساختار صفحه از روی manifest است، نه از روی یک متن حقوقی عمومی: **یک کارت به‌ازای هر
گروه مجوز** (مخاطبین، تماس‌ها، پیامک‌ها، اعلان‌ها، موقعیت مکانی، اینترنت) که می‌گوید با آن
مجوز چه می‌کند و — مهم‌تر — چه نمی‌کند (ضبط تماس نه، میکروفون نه، سرور نه)؛ بعد چهار جمله‌ی
بالا زیر «داده‌های شما»؛ بعد فهرست «آنچه هم‌رسان انجام نمی‌دهد». کارت هر مجوز runtime
وضعیت فعلی grant را هم نشان می‌دهد (فقط **خوانده** می‌شود، هرگز درخواست نمی‌شود — قانون
`PermissionGate`) و کارتِ ردشده به صفحه‌ی app-info سیستم می‌رود.

**قانون نگهداری:** مجوزی که به manifest اضافه می‌شود در همان commit یک کارت این‌جا می‌گیرد.
policy ای که یک مجوز اعلام‌شده را جا بیندازد اولین چیزی است که بازبین می‌بیند.

**نیمه‌ی دوم — انجام شد (۱۴۰۵/۰۶/۲۴):** همین متن به‌صورت `docs/privacy/index.html` (یک فایل HTML
استاتیک، فونت از Google Fonts با fallback، لوگو inline) نوشته شد و از GitHub Pages سرو می‌شود — repo
عمومی شد، Pages از شاخه‌ی `main` و پوشه‌ی `/docs`.

**وضعیت URL:** <https://ali-roodi.github.io/communication_super_app/privacy/> — همین را در فرم بازار و مایکت بگذارید.

### ✅ ۳. پشتیبان آفلاین از `upload-keystore.jks` — انجام شد (۱۴۰۵/۰۶/۲۴)

در بازار و مایکت معادلی برای **Play App Signing** وجود ندارد. این فایل به‌علاوه‌ی سه رمز داخل
`key.properties` تا همیشه هویت اپ است. از دست رفتنش یعنی هرگز نمی‌شود برای `ir.hamrasan.app`
بروزرسانی داد؛ تنها راه، انتشار مجدد با package name جدید است — یعنی از دست دادن تمام نصب‌ها و دیتای کاربران.

**چه شد:** `scripts/backup_keystore.ps1` و `scripts/backup_keystore.sh` اضافه شدند. خروجی یک آرشیو
`hamrasan-keystore-backup-<تاریخ>.tar.enc` است (AES-256-CBC، PBKDF2 با ۶۰۰ هزار دور) که `.jks`،
`key.properties`، نسخه‌ی base64 کلید (همان چیزی که secret CI می‌خواهد)، یک `RESTORE.md` با اثر انگشت
گواهی و دستور بازیابی، و `SHA256SUMS` را در خود دارد. هیچ‌چیز بیرون آرشیو به شکل خام نوشته نمی‌شود؛
خود پوشه‌ی `keystore-backup/` هم gitignore است.

دو چیز این را از یک «کپی» به «پشتیبان» تبدیل می‌کند و هر دو در همان اجرا انجام شد:

- **قبل از بسته‌بندی، keystore با رمزهای داخل `key.properties` باز می‌شود** (`keytool -list`). پشتیبانی که
  رمز ثبت‌شده‌اش غلط باشد هیچ ارزشی ندارد و این تنها لحظه‌ای است که فهمیدنش ارزان است.
- **بعد از بسته‌بندی، آرشیو دوباره باز می‌شود**، `.jks` بایت‌به‌بایت با اصل مقایسه می‌شود و `keytool` روی
  *همان نسخه‌ی بازیابی‌شده* اجرا می‌شود. اثر انگشتی که گزارش می‌شود از نسخه‌ی بازیابی‌شده است، نه اصل.

اثر انگشت SHA-256 گواهی: `58:BC:0E:5F:2F:C3:B5:BE:6F:5E:5B:AF:F0:C5:B0:2F:E7:BD:9A:8E:CA:D0:6F:86:B4:E0:E1:74:B3:C3:97:0A`
— همین چیزی است که `apksigner verify --print-certs` روی هر APK فروشگاهی باید نشان بدهد.

**کپی‌ها (۱۴۰۵/۰۶/۲۴):**

| کجا | چه | تأیید |
|---|---|---|
| لپ‌تاپ توسعه | `keystore-backup/hamrasan-keystore-backup-20260915.tar.enc` + `.sha256` | بازگشایی و مقایسه در همان اجرا |
| گوشی تست (Galaxy) | `Download/hamrasan-keystore-backup/` همان دو فایل | `sha256sum -c` روی خود گوشی: OK |
| GitHub Actions secrets | `KEYSTORE_BASE64` `KEYSTORE_PASSWORD` `KEY_PASSWORD` `KEY_ALIAS` | `gh secret list` — همان نام‌هایی که طرح CI پایین می‌خواهد |

**رمز آرشیو** در repo، آرشیو و گوشی *نیست* و قابل بازیابی هم نیست؛ در password manager نگه داشته می‌شود،
جدا از خود آرشیو. تست بازیابی با `scripts/backup_keystore.sh --restore` انجام شد (آرشیوی که PowerShell ساخته
بود، با bash باز شد و `.jks` بایت‌به‌بایت یکسان بود؛ رمز غلط رد می‌شود).

**هنوز باقی است:** یک کپی روی USB یا یک دستگاه دوم که همیشه همراه لپ‌تاپ نباشد. گوشی تست و لپ‌تاپ
معمولاً کنار هم‌اند، پس یک سرقت یا یک آتش‌سوزی هر دو را می‌برد. هر وقت USB وصل بود:
`.\scripts\backup_keystore.ps1 -OutDir E:\` — کافی است.

### ⬜ ۴. تصمیم درباره‌ی `armeabi-v7a` — تصمیم محصولی، نه باگ

بلوک `packaging { jniLibs { excludes … } }` عمداً بقیه‌ی ABIها را حذف می‌کند و دلیلش درست است
(دایرکتوری خالی v7a باعث نصب موفق روی دستگاه ۳۲بیتی و `UnsatisfiedLinkError` در اولین اجرا می‌شد).
نتیجه‌ی فروشگاهی‌اش: آن دستگاه‌ها در بازار پیام «ناسازگار» می‌بینند.

**دو گزینه:** پذیرفتن این محدودیت، یا ساختن یک APK دوم برای `armeabi-v7a` در همان pipeline
(بازار چند APK برای یک نسخه را پشتیبانی می‌کند؛ برای مایکت باید تأیید شود). گزینه‌ی دوم فقط
تغییر در pipeline است، نه در کد اپ.

**تصمیم گرفته‌شده:** _هنوز نه._

### ✅ ۵. جدا کردن `versionCode` از `pubspec.yaml` — انجام شد (۱۴۰۵/۰۶/۱۸)

`scripts/release_build.ps1` و `scripts/release_build.sh` اضافه شدند. build فروشگاهی از این مسیر ساخته می‌شود:

| مقدار | منبع |
|---|---|
| `versionName` | تگ روی HEAD (`v1.2.3` ← `1.2.3`)؛ اگر تگ نبود، از `pubspec` با اخطار |
| `versionCode` | `git rev-list --count HEAD` |

**چرا commit count و نه شماره‌ی اجرای CI:** همان عدد است چه build روی لپ‌تاپ اجرا شود چه روی
runner، هیچ state ای جایی نگه داشته نمی‌شود، و فقط زیاد می‌شود — برخلاف شمارنده‌ی هر workflow
که برای یک branch جدید از ۱ شروع می‌کند.

اسکریپت دو گارد هم دارد: اگر working tree کثیف باشد اخطار می‌دهد (APK با هیچ commit ای مطابقت
ندارد)، و اگر `apksigner verify --print-certs` بگوید `Android Debug` **build را رد می‌کند** —
دقیقاً همان چیزی که fallback به debug key در `build.gradle.kts` می‌تواند بی‌سروصدا تولید کند.

`version: 1.0.0+1` در `pubspec` دست‌نخورده ماند و حالا کامنت بالایش می‌گوید که آن `+1` فقط برای
development محلی است. `versionCode`/`versionName` در `build.gradle.kts` هم کامنت گرفتند.

**تأیید عملی (۱۴۰۵/۰۶/۱۸):** اسکریپت تا انتها اجرا شد. `aapt2 dump badging` روی APK ساخته‌شده:
`versionCode='122' versionName='1.0.0'`، و گارد امضا گواهی
`CN=Hamrasan, OU=Hamrasan App, O=Hamrasan, L=Tehran, ST=Tehran, C=IR` را خواند و تأیید کرد.

دو ایراد که همان اجرا نشان داد و اصلاح شدند — هر دو از جنس «بی‌صدا رد شدن»:

- `apksigner` یک ابزار JVM است و روی ماشینی بدون `java` در PATH فقط `JAVA_HOME is not set`
  چاپ می‌کرد. اسکریپت در آن متن دنبال `Android Debug` می‌گشت، پیدا نمی‌کرد، و امضا را **تأیید**
  می‌کرد — یعنی دقیقاً برعکس کاری که این گارد برایش هست. حالا JBR همراه Android Studio به‌عنوان
  fallback ست می‌شود و نبودِ `certificate DN:` در خروجی یک **خطا** است، نه یک تأیید.
- `android/local.properties` در gitignore است، پس روی runner وجود ندارد و خواندنش زیر `set -e`
  اسکریپت را **بعد از یک build موفق** می‌کشت. حالا اول `ANDROID_HOME` / `ANDROID_SDK_ROOT`
  خوانده می‌شود. ضمناً ویندوز فقط `apksigner.bat` دارد و لینوکس فقط نسخه‌ی بدون پسوند؛ هر دو glob می‌شوند.

### ⬜ ۶. تصمیم درباره‌ی `PROCESS_OUTGOING_CALLS` — تازه پیدا شد

هنگام حذف `RECORD_AUDIO` معلوم شد این permission هم **هیچ استفاده‌ای ندارد**: نه `NEW_OUTGOING_CALL`
receiver ای در manifest هست و نه ارجاعی در Kotlin یا Dart. از Android 10 هم عملاً کنار گذاشته شده
(مسیر شماره‌گیر پیش‌فرض `CallRedirectionService` است، نه این).

دقیقاً از همان جنس ریسکی است که `RECORD_AUDIO` بود: یک dangerous permission که reviewer دلیلی
برایش پیدا نمی‌کند.

**اقدام پیشنهادی:** حذف شود. چون برخلاف `RECORD_AUDIO` احتمال دارد به مسیر نقش شماره‌گیر گره خورده
باشد، اول روی دستگاه واقعی تأیید شود و بعد در همان commit حذف گردد.

---

## ریسک اصلی: بازبینی مجوزها

اگر اولین submission رد شود، به احتمال زیاد به‌خاطر این جدول است نه به‌خاطر باگ.

**نکته‌ی محوری:** باید در توضیحات فروشگاه **صریح** نوشته شود که این اپ جایگزین اپ پیامک و
شماره‌گیر پیش‌فرض است. آن‌وقت همه‌ی این مجوزها «کارکرد اصلی» محسوب می‌شوند نه دسترسی جانبی.
بدون آن جمله، همین لیست شبیه spyware خوانده می‌شود.

| Permission | چرا لازم است | ریسک |
|---|---|---|
| `READ_SMS` `SEND_SMS` `RECEIVE_SMS` `RECEIVE_MMS` `RECEIVE_WAP_PUSH` | شرط واجدشرایط بودن برای `ROLE_SMS` | بالا |
| `READ_CALL_LOG` `WRITE_CALL_LOG` | تب «اخیر» و mirror-sync دفترچه تماس | بالا |
| `CALL_PHONE` `MANAGE_OWN_CALLS` `READ_PHONE_STATE` | `ROLE_DIALER` و `InCallService` | متوسط |
| ~~`RECORD_AUDIO`~~ | حذف شد ۱۴۰۵/۰۶/۱۸ — استفاده‌ای نداشت | ✅ برطرف |
| `PROCESS_OUTGOING_CALLS` | **هیچ استفاده‌ای در کد ندارد** و از Android 10 کنار گذاشته شده | حذف شود (اقدام ۶) |
| `ACCESS_FINE_LOCATION` `ACCESS_COARSE_LOCATION` | فقط «موقعیت» در شیت پیوست؛ یک‌بار خوانده و به‌صورت متن در پیام درج می‌شود | متوسط |
| `USE_FULL_SCREEN_INTENT` | باز کردن صفحه‌ی تماس ورودی از نوتیفیکیشن | کم |
| `SCHEDULE_EXACT_ALARM` `USE_EXACT_ALARM` | ارسال زمان‌بندی‌شده در پس‌زمینه | کم |
| `INTERNET` | فقط link preview (متادیتای `og:`) | کم |
| `USE_BIOMETRIC` | «باز کردن با اثر انگشت یا چهره» روی قفل برنامه (اختیاری، پیش‌فرض خاموش)؛ normal permission، بدون دیالوگ. نتیجه فقط درست/نادرست است — هیچ داده‌ی بیومتریکی به برنامه نمی‌رسد | کم |

---

## مسیر اولین انتشار (دستی)

بار اول دستی است — API انتشار برای نسخه‌های بعدی طراحی شده.

**کافه‌بازار — `pishkhan.cafebazaar.ir`:** ثبت‌نام و احراز هویت (حقیقی/حقوقی) → پرداخت هزینه‌ی
یک‌بار ثبت‌نام توسعه‌دهنده → ساخت اپ با package name برابر `ir.hamrasan.app` → آپلود APK
امضاشده → اطلاعات فروشگاهی + لینک privacy policy → ارسال برای بازبینی.

**مایکت — `developer.myket.ir`:** ثبت‌نام و احراز هویت → رزرو package name → آپلود APK با
**همان** keystore بازار → اطلاعات فروشگاهی → ارسال برای بازبینی.

**دارایی‌های فروشگاهی:** آیکون ۵۱۲×۵۱۲ (از `Hamresan-Logo.svg`)، حداقل ۴ اسکرین‌شات،
توضیح کوتاه و بلند فارسی، دسته‌بندی، رده‌ی سنی، لینک privacy policy.

---

## طرح CI/CD (نوشته نشده — هر وقت لازم شد)

Trigger: تگ `v*.*.*` روی `main` + `workflow_dispatch` با ورودی درصد rollout.

1. **Gate** — `flutter analyze` و `flutter test`؛ رد شد، هیچ آپلودی انجام نمی‌شود.
2. **بازسازی keystore** — دیکد `KEYSTORE_BASE64` و ساخت `android/key.properties` در runner.
3. **Build + تأیید manifest و امضا** — `scripts/release_build.sh` (پیش‌فرض: flavor `commercial`؛ خروجی
   `build/app/outputs/flutter-apk/app-commercial-release.apk`). CI هرگز با `--flavor organization` آپلود نمی‌کند.
   همان اسکریپتی است که محلی هم اجرا می‌شود،
   پس CI و لپ‌تاپ نمی‌توانند از هم فاصله بگیرند: نسخه‌گذاری و بررسی debug key در هر دو یکسان است.
4. **آپلود بازار** — اکشن [`matinzd/cafebazaar-release`](https://github.com/matinzd/cafebazaar-release)
   با ورودی‌های `cafebazaar-pishkhaan-api-secret`، `app_file`، `staged_rollout_percentage`،
   `auto_publish`، `changelog_fa`، `changelog_en`.
5. **آپلود مایکت** — اسکریپت اختصاصی (اکشن رسمی وجود ندارد).
6. **Artifact** — نگهداری APK و `mapping.txt` مربوط به R8؛ بدون آن stack traceهای release خوانده نمی‌شوند.
7. **ثبت** — نوشتن `versionCode` منتشرشده در جدول تاریخچه‌ی همین فایل.

### Secretها

| Secret | منبع |
|---|---|
| `KEYSTORE_BASE64` | `base64 -w0 android/upload-keystore.jks` — **ثبت شد ۱۴۰۵/۰۶/۲۴** (`gh secret set`) |
| `KEYSTORE_PASSWORD` `KEY_ALIAS` `KEY_PASSWORD` | از `android/key.properties` فعلی — **ثبت شد ۱۴۰۵/۰۶/۲۴** |
| `BAZAAR_API_SECRET` | پیشخان بازار → بخش API توسعه‌دهندگان |
| `MYKET_IDENTIFIER` `MYKET_SECRET` | حساب پنل مایکت (رمز به‌صورت SHA1 ارسال می‌شود) |

### Endpointها

مسیرهای بازار از طریق اکشن آماده استفاده می‌شوند؛ جدول برای وقتی است که مستقیم با `curl` کار کنیم.
**مسیرهای مایکت رسمی مستند نشده‌اند** (از پنل استخراج شده‌اند) — ممکن است بدون اطلاع تغییر کنند،
و pipeline باید خطایشان را واضح گزارش کند.

**کافه‌بازار — `https://pishkhan.cafebazaar.ir/api`**

| مرحله | Method | مسیر |
|---|---|---|
| گرفتن نشست | `POST` | `/sessions/` |
| شروع آپلود | `GET` | `/upload/file/?file_hash&size&file_name` |
| ارسال chunk | `PATCH` | `/upload/file/{file_id}?offset&chunk_size` |
| ساخت release | `POST` | `/apps/{package}/releases/` |
| افزودن بسته | `POST` | `/apps/{package}/releases/{id}/packages/` |
| تنظیم rollout | `PATCH` | `/apps/{package}/releases/{id}` |
| ثبت نهایی | `POST` | `/apps/{package}/releases/{id}/v2/commit/` |

**مایکت — `https://developer.myket.ir/api`**

| مرحله | Method | مسیر |
|---|---|---|
| ورود | `POST` | `/dev-auth/signin/` |
| آپلود فایل | `POST` | `https://resource.myket.ir/Backload/Filehandler?objectContext={uuid}` |
| ثبت نسخه | `POST` | `/developers/{accountId}/applications/{pkg}/versions` |
| انتشار | `PUT` | `/developers/{accountId}/applications/{pkg}/confirm` |

---

## تاریخچه

| تاریخ | رویداد |
|---|---|
| ۱۴۰۵/۰۶/۱۸ | بررسی اولیه‌ی build برای انتشار. ۵ اقدام باز شناسایی شد. هنوز هیچ حسابی ساخته نشده. |
| ۱۴۰۵/۰۶/۱۸ | `RECORD_AUDIO` از manifest حذف شد (اقدام ۱). نسخه‌گذاری از git راه افتاد با `scripts/release_build.{ps1,sh}` (اقدام ۵). `PROCESS_OUTGOING_CALLS` به‌عنوان اقدام ۶ باز شد. |
| ۱۴۰۵/۰۶/۲۴ | صفحه‌ی داخل‌برنامه‌ای «حریم خصوصی و دسترسی‌ها» (`PrivacyPolicyPage`) نوشته و روی دستگاه تست شد؛ نسخه‌ی وب آن (`docs/privacy/index.html`) با GitHub Pages منتشر شد: <https://ali-roodi.github.io/communication_super_app/privacy/> (اقدام ۲ کامل). repo عمومی شد. |
| ۱۴۰۵/۰۶/۲۴ | پشتیبان keystore (اقدام ۳): `scripts/backup_keystore.{ps1,sh}` نوشته شد؛ آرشیو AES-256 ساخته و با بازگشایی تأیید شد؛ کپی روی گوشی تست با `sha256sum` تأیید شد؛ چهار secret امضا با `gh secret set` روی repo نشست. کپی USB هنوز نه. |
| ۱۴۰۵/۰۷/۰۵ | build حالا دو flavor دارد؛ فروشگاه فقط `commercial` را می‌گیرد (خروجی: `app-commercial-release.apk`). جزئیات نسخه‌ها در `docs/architecture/editions.md`. `release_build.{sh,ps1}` حالا package و versionCode و versionName را با `aapt2` از خود APK تأیید می‌کنند. باگ قدیمی `release_build.ps1` رفع شد: در Windows PowerShell 5.1 روی هر HEAD بدون تگ در خط اول می‌مرد (`git describe` روی stderr + `ErrorActionPreference=Stop`). |
| ۱۴۰۵/۰۷/۲۵ | build نهایی بعد از گواهی عضو و آزمون دو گوشی: `commercial` versionCode **۱۶۵** و `organization` **۲۰۰۰۰۰۰۱۶۵** (commit `e0e7994`). بررسی‌های اسکریپت: manifest، نبودن مرجع آزمایشی، امضای واقعی (SHA-256 `58bc0e5f…3970a`). تنها تغییر کاری درخت `.idea/caches/deviceStreaming.xml` بود. submit نشده. |

---

## منابع

- [راهنمای پیشخان بازار](https://developers.cafebazaar.ir/fa/guidelines/developers-panel/overview)
- [API توسعه‌دهندگان بازار](https://newsblog.cafebazaar.ir/developer-api-v2-c1hjqtlmulr4)
- [matinzd/cafebazaar-release](https://github.com/matinzd/cafebazaar-release)
- [راهنمای انتشار مایکت](https://myket.ir/kb/en/topics/publishing-guide/)
- [myketstore/myket-developer-api](https://github.com/myketstore/myket-developer-api)
