import 'package:flutter/material.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/widgets/jalali_date_picker.dart';
import '../models/message_template_model.dart';
import '../models/template_wire.dart';

/// Fills a template in and returns a [TemplateFillResult] (Figma «قالب آماده
/// جلسه»): the «درج نام مخاطب» switch, one input per placeholder, a live
/// preview of the result and the انصراف / تأیید pair at the bottom.
///
/// The form is *generated* from the template body — see [TemplateEngine] — so a
/// template the user wrote themselves gets exactly the same screen as a
/// built-in one, with no per-template code.
class TemplateFillScreen extends StatefulWidget {
  final MessageTemplate template;

  /// Name of the conversation's contact, when there is one. Null hides the
  /// «درج نام مخاطب» switch — there would be nothing to insert.
  final String? contactName;

  const TemplateFillScreen({
    super.key,
    required this.template,
    this.contactName,
  });

  @override
  State<TemplateFillScreen> createState() => _TemplateFillScreenState();
}

class _TemplateFillScreenState extends State<TemplateFillScreen> {
  /// Answer per placeholder name, as it will be substituted into the body.
  final Map<String, String> _values = {};

  /// The moment behind a date / time / date-time field, kept so re-opening the
  /// picker starts where the user left it.
  final Map<String, DateTime> _moments = {};

  final Map<String, TextEditingController> _controllers = {};

  /// Bumped on every answer change. The inputs are *not* rebuilt by it — only
  /// the preview and the confirm button listen, so typing does not rebuild the
  /// whole form on every keystroke.
  final ValueNotifier<int> _revision = ValueNotifier(0);

  late bool _useContactName;

  List<TemplateField> get _fields => widget.template.fields;

  String? get _contactName {
    final name = widget.contactName?.trim();
    return (name == null || name.isEmpty) ? null : name;
  }

  @override
  void initState() {
    super.initState();
    _useContactName = widget.template.useContactName && _contactName != null;

    for (final field in _fields) {
      final controller = TextEditingController();
      // A date-like field is fed by the picker rather than by typing.
      if (!field.isDateLike) {
        controller.addListener(() {
          _values[field.key] = controller.text;
          _revision.value++;
        });
      }
      _controllers[field.key] = controller;
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _revision.dispose();
    super.dispose();
  }

  /// The text as it will be inserted: unanswered placeholders are dropped.
  String get _result => TemplateEngine.render(
    widget.template.body,
    values: _values,
    contactName: _contactName,
    useContactName: _useContactName,
  );

  /// The text as shown in the preview box: unanswered placeholders are kept, so
  /// the preview reads like the template itself.
  String get _preview => TemplateEngine.render(
    widget.template.body,
    values: _values,
    contactName: _contactName,
    useContactName: _useContactName,
    preview: true,
  );

  bool get _anyAnswer => _values.values.any((v) => v.trim().isNotEmpty);

  // ── Date / time ───────────────────────────────────────────────────────────

  Future<void> _pickMoment(TemplateField field) async {
    final now = DateTime.now();
    final initial = _moments[field.key] ?? now;
    var picked = initial;

    if (field.kind != TemplateFieldKind.time) {
      final date = await showAppDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(now.year - 5),
        lastDate: DateTime(now.year + 5),
      );
      if (date == null || !mounted) return;
      picked = date;
    }

    if (field.kind != TemplateFieldKind.date) {
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(initial),
      );
      if (time == null || !mounted) return;
      picked = DateTime(
        picked.year,
        picked.month,
        picked.day,
        time.hour,
        time.minute,
      );
    }

    _moments[field.key] = picked;
    _applyMoment(field, picked);
  }

  /// Writes the picked moment into the placeholder(s) the field feeds.
  ///
  /// A merged «تاریخ و زمان» field carries two placeholders and fills each with
  /// its own half; a single placeholder that asks for both gets one combined
  /// string.
  void _applyMoment(TemplateField field, DateTime moment) {
    final date = DateFormatter.formatDate(moment);
    final time = DateFormatter.formatTime(moment);
    if (field.tokens.length == 2) {
      _values[field.tokens[0]] = date;
      _values[field.tokens[1]] = time;
    } else {
      _values[field.key] = switch (field.kind) {
        TemplateFieldKind.date => date,
        TemplateFieldKind.time => time,
        _ => '$date ساعت $time',
      };
    }
    _controllers[field.key]?.text = switch (field.kind) {
      TemplateFieldKind.date => date,
      TemplateFieldKind.time => time,
      _ => '$date - $time',
    };
    _revision.value++;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'انصراف',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text(
              widget.template.title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _fields.isEmpty
                  ? 'متن این قالب آماده است؛ می‌توانید آن را درج کنید.'
                  : 'اطلاعات خواسته‌شده را وارد کنید تا متن پیام آماده شود.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            if (_contactName != null)
              _ContactNameSwitch(
                value: _useContactName,
                onChanged: (v) {
                  setState(() => _useContactName = v);
                  _revision.value++;
                },
              ),
            for (final field in _fields) ...[
              const SizedBox(height: 12),
              _FieldInput(
                field: field,
                controller: _controllers[field.key]!,
                onPickMoment: () => _pickMoment(field),
              ),
            ],
            const SizedBox(height: 20),
            ValueListenableBuilder<int>(
              valueListenable: _revision,
              builder: (context, _, _) => _PreviewBox(text: _preview),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<int>(
                valueListenable: _revision,
                builder: (context, _, _) {
                  // «تأیید» appears once there is something to insert (Figma:
                  // the empty form shows only انصراف).
                  final ready = _fields.isEmpty || _anyAnswer;
                  return Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text(
                          'انصراف',
                          style: TextStyle(color: AppColors.danger),
                        ),
                      ),
                      if (ready)
                        TextButton(
                          onPressed: () {
                            final text = _result;
                            if (text.isEmpty) return;
                            // The payload rides along with the text it renders
                            // to; the composer sends it only while the two still
                            // match. Null for anything the receiver could not
                            // rebuild — see [TemplateWire.encode].
                            Navigator.of(context).pop(
                              TemplateFillResult(
                                text: text,
                                wire: TemplateWire.encode(
                                  template: widget.template,
                                  values: _values,
                                  greetingName: _useContactName
                                      ? _contactName
                                      : null,
                                  renderedText: text,
                                ),
                              ),
                            );
                          },
                          child: const Text('تأیید'),
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// «درج نام مخاطب» — label on one side, switch on the other (Figma).
class _ContactNameSwitch extends StatelessWidget {
  const _ContactNameSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'درج نام مخاطب',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// One generated input. Date-like fields are read-only and open a picker; the
/// rest are ordinary text fields (multi-line for «توضیحات»-shaped names).
class _FieldInput extends StatelessWidget {
  const _FieldInput({
    required this.field,
    required this.controller,
    required this.onPickMoment,
  });

  final TemplateField field;
  final TextEditingController controller;
  final VoidCallback onPickMoment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The app's global input theme is the filled pill used by the composer and
    // search bars; this form is the Figma outlined-box style, so the borders
    // are set here rather than globally.
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );

    final decoration = InputDecoration(
      labelText: field.label,
      alignLabelWithHint: field.kind == TemplateFieldKind.multiline,
      filled: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: border(scheme.outlineVariant),
      enabledBorder: border(scheme.outlineVariant),
      focusedBorder: border(scheme.primary, 2),
      prefixIcon: field.isDateLike
          ? Icon(
              field.kind == TemplateFieldKind.time
                  ? Icons.schedule_outlined
                  : Icons.event_outlined,
              color: scheme.onSurfaceVariant,
            )
          : null,
    );

    if (field.isDateLike) {
      return TextField(
        controller: controller,
        readOnly: true,
        // The field opens a picker; a caret and a keyboard here would be a lie.
        showCursor: false,
        onTap: onPickMoment,
        decoration: decoration,
      );
    }

    final multiline = field.kind == TemplateFieldKind.multiline;
    return TextField(
      controller: controller,
      minLines: multiline ? 2 : 1,
      maxLines: multiline ? 5 : 1,
      textInputAction: multiline
          ? TextInputAction.newline
          : TextInputAction.next,
      keyboardType: multiline ? TextInputType.multiline : TextInputType.text,
      decoration: decoration,
    );
  }
}

/// Live preview of the assembled message — the tonal block under the form.
class _PreviewBox extends StatelessWidget {
  const _PreviewBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
      ),
    );
  }
}
