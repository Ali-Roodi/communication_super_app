import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/selection_app_bar.dart';
import 'package:communication_super_app/core/widgets/two_column_board.dart';
import '../bloc/template_bloc.dart';
import '../bloc/template_event.dart';
import '../bloc/template_state.dart';
import '../models/message_template_model.dart';
import '../models/template_wire.dart';
import 'template_editor_screen.dart';
import 'template_fill_screen.dart';

/// Opens the template picker («انتخاب قالب») and returns the ready message —
/// the visible text plus, for a pristine built-in, the compact payload that may
/// be sent in its place (see [TemplateFillResult]) — or null if the user backed
/// out. [contactName] is offered to templates that personalise their text
/// («درج نام مخاطب»).
Future<TemplateFillResult?> showTemplatePicker(
  BuildContext context, {
  String? contactName,
}) {
  return Navigator.of(context).push<TemplateFillResult>(
    MaterialPageRoute(
      builder: (_) =>
          TemplatesListScreen(pickMode: true, contactName: contactName),
    ),
  );
}

/// Templates («قالب‌های آماده») — the same two-column note board the drafts
/// screen uses, because a template is likewise a block of text of unknown
/// length (see [SliverTwoColumnBoard]).
///
/// Two modes:
/// * **manage** (from the inbox menu) — tap edits, long-press multi-selects.
/// * **pick** ([pickMode], from the composer «+» sheet) — tap fills the
///   template in and pops with the finished text; multi-select is off, there is
///   nothing to act on in bulk while choosing one template to insert.
class TemplatesListScreen extends StatefulWidget {
  final bool pickMode;

  /// Name of the conversation's contact, when there is one.
  final String? contactName;

  const TemplatesListScreen({
    super.key,
    this.pickMode = false,
    this.contactName,
  });

  @override
  State<TemplatesListScreen> createState() => _TemplatesListScreenState();
}

class _TemplatesListScreenState extends State<TemplatesListScreen> {
  bool get pickMode => widget.pickMode;

  final Set<String> _selected = {};

  bool get _selectionMode => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final bloc = context.read<TemplateBloc>();
    if (bloc.state is! TemplatesLoaded) bloc.add(const LoadTemplates());
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: scheme.pageBackground,
        appBar: _selectionMode
            ? SelectionAppBar(
                selectedCount: _selected.length,
                onClear: _clearSelection,
                actions: _selectionActions(context),
              )
            : AppBar(
                title: Text(pickMode ? 'انتخاب قالب' : 'قالب‌های آماده'),
                backgroundColor: scheme.pageBackground,
                surfaceTintColor: Colors.transparent,
                actions: [
                  IconButton(
                    icon: const Icon(Icons.info_outline),
                    tooltip: 'راهنما',
                    onPressed: () => _showHelp(context),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
        body: BlocBuilder<TemplateBloc, TemplateState>(
          builder: (context, state) {
            if (state is TemplateLoading || state is TemplateInitial) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state is TemplateError) {
              return Center(child: Text('خطا: ${state.message}'));
            }
            if (state is! TemplatesLoaded) return const SizedBox.shrink();

            // A template may have been deleted from under the selection; never
            // let the contextual bar count rows that are gone.
            final visible = {for (final t in state.templates) t.id};
            final live = _selected.where(visible.contains).toSet();
            if (live.length != _selected.length) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() {
                    _selected
                      ..clear()
                      ..addAll(live);
                  });
                }
              });
            }

            return Container(
              decoration: BoxDecoration(
                color: scheme.cardSurface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: CustomScrollView(
                slivers: [
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  if (state.templates.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: Icons.description_outlined,
                        title: 'قالبی وجود ندارد',
                        subtitle:
                            'قالب‌های آماده برای پیام‌های پرتکرار اینجا نگهداری می‌شوند',
                      ),
                    )
                  else
                    SliverTwoColumnBoard<MessageTemplate>(
                      items: state.templates,
                      itemBuilder: (context, template) => _TemplateCard(
                        template: template,
                        selectionMode: _selectionMode,
                        selected: _selected.contains(template.id),
                        onTap: () => _onTemplateTap(context, template),
                        onLongPress: pickMode
                            ? null
                            : () {
                                HapticFeedback.mediumImpact();
                                _toggle(template.id);
                              },
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 96)),
                ],
              ),
            );
          },
        ),
        // Shown in pick mode too, so a template can be written on the spot
        // while choosing one to insert.
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton(
                heroTag: 'templates_fab',
                tooltip: 'قالب جدید',
                onPressed: () => _openEditor(context),
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  // ── Selection bar ─────────────────────────────────────────────────────────

  List<Widget> _selectionActions(BuildContext context) {
    final state = context.read<TemplateBloc>().state;
    final all = state is TemplatesLoaded
        ? state.templates
        : const <MessageTemplate>[];
    final chosen = all.where((t) => _selected.contains(t.id)).toList();

    return [
      IconButton(
        icon: const Icon(Icons.push_pin_outlined),
        tooltip: 'سنجاق',
        onPressed: chosen.isEmpty ? null : () => _pinSelected(context, chosen),
      ),
      // Editing is single-selection: there is one form behind one template.
      if (chosen.length == 1)
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'ویرایش',
          onPressed: () {
            final template = chosen.first;
            _clearSelection();
            _openEditor(context, template: template);
          },
        ),
      IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'حذف',
        onPressed: chosen.isEmpty ? null : () => _confirmDelete(context, chosen),
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: 'انتخاب همه',
        onPressed: () => setState(() {
          _selected
            ..clear()
            ..addAll(all.map((t) => t.id));
        }),
      ),
    ];
  }

  /// Pins the selection; if every chosen template is already pinned the action
  /// unpins instead — the mixed-selection convention the inbox uses.
  void _pinSelected(BuildContext context, List<MessageTemplate> chosen) {
    final pin = chosen.any((t) => !t.isPinned);
    context.read<TemplateBloc>().add(
      PinTemplates(chosen.map((t) => t.id).toList(), pin: pin),
    );
    _clearSelection();
  }

  Future<void> _confirmDelete(
    BuildContext context,
    List<MessageTemplate> chosen,
  ) async {
    final bloc = context.read<TemplateBloc>();
    final messenger = ScaffoldMessenger.of(context);
    final count = PersianUtils.toPersianNumber('${chosen.length}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          content: Text('$count قالب حذف شود؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('انصراف'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'حذف',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final removed = List<MessageTemplate>.from(chosen);
    bloc.add(DeleteTemplates(removed.map((t) => t.id).toList()));
    _clearSelection();
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('$count قالب حذف شد'),
          action: SnackBarAction(
            label: 'واگرد',
            // Re-saving restores the text under a fresh id; a pinned template
            // comes back unpinned, which is the honest outcome of "the row is
            // gone" rather than a half-restored one.
            onPressed: () {
              for (final t in removed) {
                bloc.add(
                  SaveTemplate(
                    title: t.title,
                    body: t.body,
                    useContactName: t.useContactName,
                  ),
                );
              }
            },
          ),
        ),
      );
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _openEditor(BuildContext context, {MessageTemplate? template}) {
    final bloc = context.read<TemplateBloc>();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: bloc,
          child: TemplateEditorScreen(template: template),
        ),
      ),
    );
  }

  Future<void> _onTemplateTap(
    BuildContext context,
    MessageTemplate template,
  ) async {
    if (_selectionMode) {
      _toggle(template.id);
      return;
    }
    if (!pickMode) {
      _openEditor(context, template: template);
      return;
    }

    final name = widget.contactName?.trim();
    final hasName = name != null && name.isNotEmpty;

    // A template with nothing to fill in is a one-tap insert (the old quick
    // templates); anything else goes through the fill screen. Nothing to fill
    // in means nothing to compress either, so it ships as plain text.
    if (!template.needsInput(hasContactName: hasName)) {
      Navigator.of(
        context,
      ).pop(TemplateFillResult(text: TemplateEngine.render(template.body)));
      return;
    }

    final result = await Navigator.of(context).push<TemplateFillResult>(
      MaterialPageRoute(
        builder: (_) => TemplateFillScreen(
          template: template,
          contactName: hasName ? name : null,
        ),
      ),
    );
    if (result != null && result.text.isNotEmpty && context.mounted) {
      Navigator.of(context).pop(result);
    }
  }

  void _showHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('قالب آماده'),
          content: const Text(
            'قالب، متن آماده‌ای برای پیام‌های پرتکرار است.\n\n'
            'هر عبارتی که داخل کروشه بنویسید (مثل [عنوان] یا [مکان]) هنگام '
            'استفاده از قالب به‌صورت یک فیلد پرسیده می‌شود و جای آن پر می‌شود.\n\n'
            '[تاریخ] و [زمان] با یک انتخابگر تاریخ و ساعت پر می‌شوند.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('متوجه شدم'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One card on the board: template title + a preview of its text.
class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    required this.template,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final MessageTemplate template;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      template.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  if (template.isPinned && !selectionMode) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.push_pin,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                  if (selectionMode) ...[
                    const SizedBox(width: 6),
                    SelectionCheck(selected: selected, size: 22),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                template.body,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
