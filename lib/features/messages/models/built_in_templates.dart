import 'message_template_model.dart';

/// One template that ships **inside the app binary**.
///
/// The built-ins exist twice on purpose: as rows in `message_templates` (which
/// the user may edit, pin or delete — see `DatabaseHelper._seedMessageTemplates`,
/// which seeds them from this very list) and as these compiled-in constants.
///
/// The constants are what the SMS wire format ([TemplateWire]) is bound to. A
/// row is mutable, and two phones do not have the same rows: if the wire
/// carried a row id and the receiver rebuilt the message from *its* copy of
/// that row, one side editing «دعوت‌نامه جلسه» would silently rewrite the other
/// side's incoming messages. Bound to a constant, a payload decodes to the same
/// text on every install of the same build, and a template the user edited
/// simply stops qualifying for the compact format (see [BuiltInTemplates.of]).
class BuiltInTemplate {
  /// Row id in `message_templates`. Stable — it is what the seed inserts.
  final String id;

  /// Short code carried on the wire. Kept to 3 ASCII letters: every Persian
  /// character in an SMS costs two bytes (UCS-2), so the header has to be cheap.
  /// **Never reuse or repurpose a code** — an old message on someone's phone
  /// still decodes through it.
  final String code;

  final String title;
  final String body;
  final bool useContactName;

  BuiltInTemplate({
    required this.id,
    required this.code,
    required this.title,
    required this.body,
    required this.useContactName,
  });

  /// Placeholder names in wire order — the payload is positional, so this order
  /// is part of the format. It derives from [body], which is a constant.
  late final List<String> tokens = TemplateEngine.tokensOf(body);

  /// Nothing to compress: a template without placeholders is the same text on
  /// both sides, so it ships as ordinary SMS.
  bool get isFillable => tokens.isNotEmpty;

  MessageTemplate toTemplate({
    required DateTime updatedAt,
    bool isPinned = false,
  }) => MessageTemplate(
    id: id,
    title: title,
    body: body,
    useContactName: useContactName,
    isPinned: isPinned,
    updatedAt: updatedAt,
  );
}

/// The compiled-in template catalogue.
abstract class BuiltInTemplates {
  /// Seed order is display order: `_seedMessageTemplates` stamps each row a
  /// millisecond older than the one before, so the board opens in this order.
  static final List<BuiltInTemplate> all = [
    BuiltInTemplate(
      id: 'tpl-meeting',
      code: 'mtg',
      title: 'دعوت‌نامه جلسه',
      body:
          'جلسه [عنوان] در مورخه [تاریخ] ساعت [زمان] در محل [مکان] برقرار می‌باشد.\n[توضیحات]',
      useContactName: true,
    ),
    BuiltInTemplate(
      id: 'tpl-reminder',
      code: 'rmd',
      title: 'یادآوری قرار',
      body:
          'یادآوری می‌شود [عنوان] در مورخه [تاریخ] ساعت [زمان] برگزار می‌شود.',
      useContactName: true,
    ),
    BuiltInTemplate(
      id: 'tpl-payment',
      code: 'pay',
      title: 'اطلاع واریز',
      body:
          'مبلغ [مبلغ] تومان بابت [بابت] در تاریخ [تاریخ] واریز شد.\n[توضیحات]',
      useContactName: true,
    ),
    BuiltInTemplate(
      id: 'tpl-congrats',
      code: 'cng',
      title: 'تبریک',
      body: '[مناسبت] را صمیمانه به شما تبریک می‌گویم.',
      useContactName: true,
    ),
    BuiltInTemplate(
      id: 'tpl-thanks',
      code: 'thx',
      title: 'تشکر',
      body: 'با سلام، از پیگیری و همراهی شما سپاسگزارم.',
      useContactName: false,
    ),
    BuiltInTemplate(
      id: 'tpl-followup',
      code: 'fup',
      title: 'پیگیری',
      body:
          'با سلام، جهت پیگیری موضوع مطرح‌شده مزاحم شدم. ممنون می‌شوم در صورت امکان پاسخ بفرمایید.',
      useContactName: false,
    ),
    BuiltInTemplate(
      id: 'tpl-call',
      code: 'cal',
      title: 'هماهنگی تماس',
      body: 'با سلام، چه زمانی برای یک تماس کوتاه در دسترس هستید؟',
      useContactName: false,
    ),
    BuiltInTemplate(
      id: 'tpl-apology',
      code: 'apl',
      title: 'عذرخواهی بابت تأخیر',
      body: 'با سلام، بابت تأخیر پیش‌آمده پوزش می‌خواهم. [توضیحات]',
      useContactName: false,
    ),
  ];

  static final Map<String, BuiltInTemplate> _byCode = {
    for (final t in all) t.code: t,
  };
  static final Map<String, BuiltInTemplate> _byId = {
    for (final t in all) t.id: t,
  };

  static BuiltInTemplate? byCode(String code) => _byCode[code];

  static BuiltInTemplate? byId(String id) => _byId[id];

  /// The built-in [template] still *is*, or null.
  ///
  /// Matching on the id alone is not enough: the seeded rows are ordinary rows
  /// the user may edit, and an edited body no longer reconstructs from the
  /// compiled-in constant. Such a template falls back to sending its full text.
  static BuiltInTemplate? of(MessageTemplate template) {
    final builtIn = _byId[template.id];
    if (builtIn == null) return null;
    return builtIn.body == template.body ? builtIn : null;
  }
}
