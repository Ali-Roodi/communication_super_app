import 'package:flutter/material.dart';

import 'package:communication_super_app/features/contacts/services/contact_filters.dart';

/// The filter row of the contacts tab and the inbox (matrix row 36):
/// «همه», then each visible [ContactFilter], then a button that opens
/// [showContactFilterEditor] to show or hide them.
///
/// Draws nothing when there is no filter at all — a phone with no label and no
/// messenger keeps its screens as they were.
class ContactFilterBar extends StatelessWidget {
  const ContactFilterBar({
    super.key,
    required this.filters,
    required this.all,
    required this.selected,
    required this.onSelected,
  });

  /// The chips on show.
  final List<ContactFilter> filters;

  /// Every filter, hidden ones included — what the editor lists.
  final List<ContactFilter> all;

  final ContactFilter? selected;
  final ValueChanged<ContactFilter?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (all.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        children: [
          ChoiceChip(
            label: const Text('همه'),
            selected: selected == null,
            onSelected: (_) => onSelected(null),
          ),
          for (final filter in filters) ...[
            const SizedBox(width: 8),
            ChoiceChip(
              avatar: _avatarOf(filter),
              label: Text(filter.title),
              selected: filter == selected,
              onSelected: (_) => onSelected(filter == selected ? null : filter),
            ),
          ],
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'نمایش یا پنهان کردن گروه‌ها',
            visualDensity: VisualDensity.compact,
            onPressed: () => showContactFilterEditor(context, all),
          ),
        ],
      ),
    );
  }

  static Widget? _avatarOf(ContactFilter filter) {
    switch (filter.kind) {
      case ContactFilterKind.messenger:
        final icon = filter.icon;
        return icon == null
            ? const Icon(Icons.chat_bubble_outline, size: 18)
            : ClipOval(
                child: Image.memory(
                  icon,
                  width: 20,
                  height: 20,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.chat_bubble_outline, size: 18),
                ),
              );
      case ContactFilterKind.secure:
        return const Icon(Icons.lock_outline, size: 18);
      case ContactFilterKind.label:
        return null;
    }
  }
}

/// «نمایش گروه‌ها» — a switch per filter; a hidden one leaves the row (on
/// both screens) but nothing about its contacts changes.
Future<void> showContactFilterEditor(
  BuildContext context,
  List<ContactFilter> all,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: ValueListenableBuilder<int>(
          valueListenable: ContactFilters.instance.revision,
          builder: (context, _, _) => ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    'نمایش گروه‌ها',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final filter in all)
                  SwitchListTile(
                    secondary: _editorIcon(filter),
                    title: Text(filter.title),
                    subtitle: Text(_kindLabel(filter.kind)),
                    value: !ContactFilters.instance.isHidden(filter),
                    onChanged: (show) =>
                        ContactFilters.instance.setHidden(filter, !show),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _editorIcon(ContactFilter filter) {
  switch (filter.kind) {
    case ContactFilterKind.label:
      return const Icon(Icons.label_outline);
    case ContactFilterKind.messenger:
      final icon = filter.icon;
      return icon == null
          ? const Icon(Icons.chat_bubble_outline)
          : ClipOval(
              child: Image.memory(
                icon,
                width: 24,
                height: 24,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.chat_bubble_outline),
              ),
            );
    case ContactFilterKind.secure:
      return const Icon(Icons.lock_outline);
  }
}

String _kindLabel(ContactFilterKind kind) => switch (kind) {
  ContactFilterKind.label => 'برچسب',
  ContactFilterKind.messenger => 'مخاطبین این پیام‌رسان',
  ContactFilterKind.secure => 'گفتگوهای رمز',
};
