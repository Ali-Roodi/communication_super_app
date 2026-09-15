import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';

/// «حریم خصوصی و دسترسی‌ها» — the privacy policy, told permission by
/// permission.
///
/// Both stores require a privacy policy before an SMS/dialer app can be
/// submitted, and the reviewer's real question is never "is there a policy"
/// but "why does this app hold READ_SMS and READ_CALL_LOG". So the page is
/// structured around the manifest: one card per permission group, each saying
/// what the app does with it and — just as important — what it does *not* do.
/// The copy must stay true to the manifest and to `docs/publishing/
/// store-release.md`; a permission added there gets a card here in the same
/// commit, because a policy that omits a declared permission is the thing a
/// store reviewer notices first.
///
/// Each runtime card also shows its **live grant state**, read (never
/// requested — see `PermissionGate`) through `permission_handler`, so the page
/// doubles as the one place a user can see what they have actually allowed.
/// Tapping a refused card opens the system app-info page, which is the only
/// surface that can change a grant the user already denied.
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'حریم خصوصی و دسترسی‌ها'),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
          children: [
            GroupedCard(
              padding: EdgeInsets.zero,
              radius: 28,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        'هم‌رسان برای این‌که بتواند جای برنامه‌ی پیامک و '
                        'تلفن گوشی شما را بگیرد، به دسترسی‌های زیر نیاز دارد. '
                        'هر دسترسی فقط برای همان کاری استفاده می‌شود که '
                        'این‌جا نوشته شده و هیچ‌کدام از داده‌های شما از گوشی '
                        'خارج نمی‌شود:',
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.8,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    for (final entry in _permissionEntries) ...[
                      _PermissionCard(entry: entry),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
            ),
            const SectionLabel('داده‌های شما'),
            const _DataPolicyGroup(),
            const SectionLabel('آنچه هم‌رسان انجام نمی‌دهد'),
            const _NeverGroup(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: Text(
                'این متن با هر تغییری در دسترسی‌های برنامه به‌روز می‌شود. '
                'اگر پرسشی درباره‌ی حریم خصوصی دارید، از صفحه‌ی برنامه در '
                'فروشگاه با ما در تماس باشید.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.7,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Permission cards ─────────────────────────────────────────────────────────

/// One card on the page. [permission] is null for a grant that is not a
/// runtime permission (INTERNET) — such a card has no state to show.
class _PermissionEntry {
  final IconData icon;
  final String title;
  final String body;
  final Permission? permission;

  const _PermissionEntry({
    required this.icon,
    required this.title,
    required this.body,
    this.permission,
  });
}

/// Ordered the way the permission gate asks for them, then the on-demand ones.
/// [Permission.phone] covers CALL_PHONE / READ_PHONE_STATE / READ_CALL_LOG on
/// Android, which is why «تماس‌ها» is one card and not three.
const List<_PermissionEntry> _permissionEntries = [
  _PermissionEntry(
    icon: Icons.person_outline,
    title: 'دسترسی به مخاطبین',
    permission: Permission.contacts,
    body:
        'برای این‌که به‌جای شماره، نام مخاطب را در فهرست پیام‌ها، تماس‌های '
        'اخیر و صفحه‌ی تماس ورودی ببینید، و بتوانید از داخل برنامه مخاطب '
        'جدید بسازید یا ویرایش کنید. دفترچه‌ی تلفن همان دفترچه‌ی گوشی شماست؛ '
        'هم‌رسان نسخه‌ی جداگانه‌ای از آن نگه نمی‌دارد و هرگز آن را جایی '
        'ارسال نمی‌کند.',
  ),
  _PermissionEntry(
    icon: Icons.phone_outlined,
    title: 'دسترسی به تماس‌ها',
    permission: Permission.phone,
    body:
        'برای برقراری تماس از صفحه‌کلید، پاسخ دادن به تماس ورودی، نمایش '
        'تماس‌های اخیر و تشخیص این‌که کدام سیم‌کارت در حال استفاده است. '
        'هم‌رسان به‌عنوان برنامه‌ی پیش‌فرض تلفن، صفحه‌ی تماس را خودش نمایش '
        'می‌دهد؛ اما هیچ تماسی ضبط نمی‌شود و برنامه اصلاً دسترسی میکروفون '
        'ندارد.',
  ),
  _PermissionEntry(
    icon: Icons.chat_bubble_outline,
    title: 'دسترسی به پیامک‌ها',
    permission: Permission.sms,
    body:
        'برای دریافت، نمایش و ارسال پیامک — کاری که یک برنامه‌ی پیامک برای '
        'آن ساخته شده. پیام‌های شما فقط روی همین گوشی و در پایگاه‌داده‌ی '
        'داخلی برنامه نگهداری می‌شوند. متن هیچ پیامی خوانده، تحلیل یا به '
        'سروری ارسال نمی‌شود و رمزهای یک‌بارمصرف روی همین دستگاه تشخیص '
        'داده می‌شوند.',
  ),
  _PermissionEntry(
    icon: Icons.notifications_none_outlined,
    title: 'دسترسی به اعلان‌ها',
    permission: Permission.notification,
    body:
        'برای این‌که پیامک تازه و تماس ورودی را همان لحظه ببینید، حتی وقتی '
        'برنامه باز نیست یا گوشی قفل است. بدون این دسترسی، برنامه هم‌چنان '
        'کار می‌کند اما از پیام یا تماس جدید باخبر نمی‌شوید.',
  ),
  _PermissionEntry(
    icon: Icons.location_on_outlined,
    title: 'دسترسی به موقعیت مکانی',
    permission: Permission.location,
    body:
        'فقط وقتی خودتان در پنجره‌ی پیوست، «موقعیت» را انتخاب کنید. مختصات '
        'یک بار خوانده می‌شود و به‌صورت متن داخل همان پیام قرار می‌گیرد؛ '
        'همین. هیچ ردیابی در پس‌زمینه وجود ندارد و موقعیت شما هیچ‌جا ذخیره '
        'نمی‌شود.',
  ),
  _PermissionEntry(
    icon: Icons.language_outlined,
    title: 'دسترسی به اینترنت',
    body:
        'برای نمایش پیش‌نمایش لینک‌هایی که داخل پیام‌ها هستند (عنوان و '
        'تصویر صفحه). در این حالت فقط همان نشانی از گوشی شما باز می‌شود — '
        'نه متن پیام، نه شماره‌ی فرستنده. تنها استفاده‌ی دیگر، گزارش خطاست '
        'که پیش‌فرض خاموش است و فقط با انتخاب خودتان فعال می‌شود. هم‌رسان '
        'سرور مخصوص به خود ندارد.',
  ),
];

/// A tonal card: tinted icon disc, bold title, explanation, and — for a
/// runtime permission — its current grant state as a small footer.
class _PermissionCard extends StatefulWidget {
  final _PermissionEntry entry;
  const _PermissionCard({required this.entry});

  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard>
    with WidgetsBindingObserver {
  PermissionStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from the system app-info page is the only way a grant here
  /// can change, so the state is re-read on every resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final permission = widget.entry.permission;
    if (permission == null) return;
    // A read, never a request: the request path belongs to `PermissionGate`.
    final status = await permission.status;
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entry = widget.entry;
    final status = _status;
    final granted = status?.isGranted ?? false;
    final showState = entry.permission != null && status != null;

    return Material(
      color: scheme.tonalRow,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        // Only a refused grant has somewhere to go; a granted one is a fact.
        onTap: showState && !granted ? openAppSettings : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      entry.icon,
                      size: 22,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      entry.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                entry.body,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.8,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (showState) ...[
                const SizedBox(height: 12),
                _StatusChip(granted: granted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// «داده شده» / «داده نشده · تنظیمات» — a dot and a word, not a switch: the
/// page cannot change a grant, it can only say what it is.
class _StatusChip extends StatelessWidget {
  final bool granted;
  const _StatusChip({required this.granted});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = granted ? scheme.primary : scheme.error;
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          granted ? 'دسترسی داده شده' : 'دسترسی داده نشده',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        if (!granted) ...[
          const Spacer(),
          Text(
            'تغییر در تنظیمات',
            style: TextStyle(fontSize: 13, color: scheme.primary),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_left, size: 18, color: scheme.primary),
        ],
      ],
    );
  }
}

// ── Data policy ──────────────────────────────────────────────────────────────

/// The four sentences the store form asks for, each as its own row. They must
/// stay in step with the build: `allowBackup=false` in the manifest, the
/// opt-in-and-redacted crash reporter, and the absence of any server.
class _DataPolicyGroup extends StatelessWidget {
  const _DataPolicyGroup();

  @override
  Widget build(BuildContext context) {
    return const GroupedList(
      children: [
        _PolicyRow(
          icon: Icons.phone_android_outlined,
          title: 'همه‌چیز روی گوشی شما می‌ماند',
          body:
              'پیام‌ها، سابقه‌ی تماس‌ها و تنظیمات فقط در پایگاه‌داده‌ی داخلی '
              'برنامه روی همین دستگاه ذخیره می‌شوند.',
        ),
        _PolicyRow(
          icon: Icons.cloud_off_outlined,
          title: 'هیچ سروری در کار نیست',
          body:
              'هم‌رسان حساب کاربری ندارد و هیچ پیام، مخاطب یا شماره‌ای را '
              'به هیچ سروری — نه ما، نه دیگران — ارسال نمی‌کند.',
        ),
        _PolicyRow(
          icon: Icons.backup_outlined,
          title: 'پشتیبان‌گیری سیستمی خاموش است',
          body:
              'داده‌های برنامه عمداً در پشتیبان‌گیری خودکار اندروید قرار '
              'نمی‌گیرند تا نسخه‌ای از پیام‌های شما بدون قفل برنامه جایی '
              'کپی نشود.',
        ),
        _PolicyRow(
          icon: Icons.bug_report_outlined,
          title: 'گزارش خطا پیش‌فرض خاموش است',
          body:
              'فقط اگر خودتان آن را روشن کنید، محل بروز خطا ارسال می‌شود؛ '
              'حتی در آن حالت هم متن پیام‌ها، شماره‌ها و نام‌ها پیش از ارسال '
              'حذف می‌شوند.',
        ),
        _PolicyRow(
          icon: Icons.lock_outline,
          title: 'قفل برنامه اختیاری است',
          body:
              'رمز یا الگوی قفل برنامه به‌صورت درهم‌سازی‌شده در حافظه‌ی امن '
              'گوشی نگهداری می‌شود و هرگز به شکل خام ذخیره نمی‌شود.',
        ),
      ],
    );
  }
}

/// What a reviewer (and a wary user) would otherwise have to guess.
class _NeverGroup extends StatelessWidget {
  const _NeverGroup();

  @override
  Widget build(BuildContext context) {
    return const GroupedList(
      children: [
        _PolicyRow(
          icon: Icons.mic_off_outlined,
          title: 'تماس‌ها را ضبط نمی‌کند',
        ),
        _PolicyRow(
          icon: Icons.visibility_off_outlined,
          title: 'محتوای پیام‌ها را تحلیل نمی‌کند',
        ),
        _PolicyRow(
          icon: Icons.campaign_outlined,
          title: 'تبلیغات یا ابزار ردیابی ندارد',
        ),
        _PolicyRow(
          icon: Icons.person_off_outlined,
          title: 'حساب کاربری یا ثبت‌نام نمی‌خواهد',
        ),
      ],
    );
  }
}

class _PolicyRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;

  const _PolicyRow({required this.icon, required this.title, this.body});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 24, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.4,
                    color: scheme.onSurface,
                  ),
                ),
                if (body != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    body!,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
