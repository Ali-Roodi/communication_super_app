import 'package:flutter/material.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';

/// Opens the template picker (Figma «انتخاب قالب») and returns the generated
/// message text, or null if cancelled. [contactName] is offered to templates
/// that can personalise the text (e.g. the meeting invitation).
Future<String?> showTemplatePicker(BuildContext context,
    {String? contactName}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => _TemplatePickerScreen(contactName: contactName),
    ),
  );
}

/// Built-in quick templates that insert a fixed body with no further input.
const _quickTemplates = <({String title, String body})>[
  (
    title: 'تشکر',
    body: 'با سلام، از پیگیری و همراهی شما سپاسگزارم.'
  ),
  (
    title: 'پیگیری',
    body: 'با سلام، جهت پیگیری موضوع مطرح‌شده مزاحم شدم. ممنون می‌شوم در صورت امکان پاسخ بفرمایید.'
  ),
  (
    title: 'هماهنگی تماس',
    body: 'با سلام، چه زمانی برای یک تماس کوتاه در دسترس هستید؟'
  ),
  (
    title: 'عذرخواهی',
    body: 'با سلام، بابت تأخیر پیش‌آمده پوزش می‌خواهم.'
  ),
];

class _TemplatePickerScreen extends StatelessWidget {
  final String? contactName;
  const _TemplatePickerScreen({this.contactName});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('انتخاب قالب')),
        body: ListView(
          padding: const EdgeInsets.all(AppDimensions.paddingMd),
          children: [
            // Form-based template: meeting invitation.
            _TemplateCard(
              icon: Icons.event_outlined,
              title: 'دعوت‌نامه جلسه',
              subtitle: 'جزئیات جلسه را وارد کنید تا متن دعوت‌نامه آماده شود.',
              onTap: () async {
                final text = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) =>
                        MeetingTemplateScreen(contactName: contactName),
                  ),
                );
                if (text != null && context.mounted) {
                  Navigator.of(context).pop(text);
                }
              },
            ),
            const SizedBox(height: AppDimensions.paddingSm),
            ..._quickTemplates.map((t) => _TemplateCard(
                  icon: Icons.notes_outlined,
                  title: t.title,
                  subtitle: t.body,
                  onTap: () => Navigator.of(context).pop(t.body),
                )),
          ],
        ),
      ),
    );
  }
}

class _TemplateCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _TemplateCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimensions.listItemGap),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppDimensions.paddingMd),
            child: Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: AppDimensions.paddingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_left),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fillable meeting-invitation template (Figma «قالب آماده جلسه»).
/// Builds the invitation text from the entered details and returns it.
class MeetingTemplateScreen extends StatefulWidget {
  final String? contactName;
  const MeetingTemplateScreen({super.key, this.contactName});

  @override
  State<MeetingTemplateScreen> createState() => _MeetingTemplateScreenState();
}

class _MeetingTemplateScreenState extends State<MeetingTemplateScreen> {
  final _title = TextEditingController();
  final _dateTime = TextEditingController();
  final _location = TextEditingController();
  final _description = TextEditingController();
  bool _insertName = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _dateTime, _location, _description]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _dateTime.dispose();
    _location.dispose();
    _description.dispose();
    super.dispose();
  }

  /// Assembles the invitation, omitting any blank fields.
  String _build() {
    final buffer = StringBuffer();
    final name = widget.contactName;
    if (_insertName && name != null && name.isNotEmpty) {
      buffer.write('$name عزیز، ');
    }
    buffer.write('جلسه');
    if (_title.text.trim().isNotEmpty) buffer.write(' «${_title.text.trim()}»');
    if (_dateTime.text.trim().isNotEmpty) {
      buffer.write(' در مورخه ${_dateTime.text.trim()}');
    }
    if (_location.text.trim().isNotEmpty) {
      buffer.write(' در محل ${_location.text.trim()}');
    }
    buffer.write(' برقرار می‌باشد.');
    if (_description.text.trim().isNotEmpty) {
      buffer.write(' ${_description.text.trim()}');
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _build();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('قالب آماده جلسه'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppDimensions.paddingSm, vertical: 8),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_build()),
                child: const Text('درج'),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(AppDimensions.paddingMd),
          children: [
            Text(
              'جزئیات جلسه را وارد کنید تا متن دعوت‌نامه آماده شود.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppDimensions.paddingMd),
            if (widget.contactName != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('درج نام مخاطب'),
                value: _insertName,
                onChanged: (v) => setState(() => _insertName = v),
              ),
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'عنوان'),
            ),
            const SizedBox(height: AppDimensions.paddingMd),
            TextField(
              controller: _dateTime,
              decoration: const InputDecoration(
                labelText: 'تاریخ و زمان',
                prefixIcon: Icon(Icons.event_outlined),
              ),
            ),
            const SizedBox(height: AppDimensions.paddingMd),
            TextField(
              controller: _location,
              decoration: const InputDecoration(labelText: 'مکان'),
            ),
            const SizedBox(height: AppDimensions.paddingMd),
            TextField(
              controller: _description,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'توضیحات',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: AppDimensions.paddingLg),
            // Live preview of the generated invitation.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppDimensions.paddingMd),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppDimensions.radiusMd),
              ),
              child: Text(preview, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}
