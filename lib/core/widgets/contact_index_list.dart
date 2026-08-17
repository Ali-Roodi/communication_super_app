import 'dart:async';

import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/persian_alphabet.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';

/// The A–Z (or ا–ی) sectioning and fast-scroll bar every address-book list in the
/// app shares: the contacts tab and the «پیام جدید» recipient picker.
///
/// Extracted when the picker needed the same list. Duplicating it would have
/// meant two alphabets, two rank functions and two jump-offset calculations — and
/// the jump only lands on the right name while the list's order, the index bar's
/// ranks and the row height agree, so a second copy is a fast-scroll that drifts.

/// Fixed extents so the jump offsets can be computed without laying the list out.
///
/// Sized for two lines (name + numbers), not one — a name-only row cannot tell
/// two contacts with the same name apart. Changing this means changing the row.
const double kContactRowHeight = 72;
const double kContactHeaderHeight = 44;

/// One alphabetical run of contacts.
class ContactSection {
  const ContactSection(this.letter, this.contacts);
  final String letter;
  final List<ContactModel> contacts;
}

/// Buckets [contacts] into sections by [ContactModel.sortName]'s section letter.
///
/// `sortName`, not `name`: under «مرتب‌سازی بر اساس نام خانوادگی» a row belongs to
/// the section of the family name, which is not the letter its displayed name
/// starts with. The input is expected to be already ordered (the repository sorts
/// it with `PersianCollator`), so this only groups and orders the *letters*.
List<ContactSection> buildContactSections(
  List<ContactModel> contacts,
  List<String> letters,
) {
  final grouped = <String, List<ContactModel>>{};
  for (final contact in contacts) {
    grouped
        .putIfAbsent(sectionLetterFor(contact.sortName, letters), () => [])
        .add(contact);
  }
  final keys = grouped.keys.toList()
    ..sort((a, b) => letterRank(a, letters).compareTo(letterRank(b, letters)));
  return [for (final key in keys) ContactSection(key, grouped[key]!)];
}

/// Scroll offset of the first section at or after [letter], or null when there is
/// nothing at or after it.
///
/// The bar always shows the whole alphabet but not every letter has a section, so
/// a tap lands on the next one that does — stock-phone behaviour.
double? sectionJumpOffset(
  List<ContactSection> sections,
  String letter,
  List<String> letters, {
  double headerHeight = kContactHeaderHeight,
  double rowHeight = kContactRowHeight,
  double leadingOffset = 0,
}) {
  final targetRank = letterRank(letter, letters);
  var acc = leadingOffset;
  for (final section in sections) {
    if (letterRank(section.letter, letters) >= targetRank) return acc;
    acc += headerHeight + section.contacts.length * rowHeight;
  }
  return null;
}

/// The inline «ا» / «A» section heading.
///
/// Deliberately **not** pinned: Flutter stacks every pinned persistent header at
/// the top as the list scrolls, which piled the letters up and pushed the rows
/// off the screen. Fast navigation is the alphabet bar's job.
class ContactSectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  ContactSectionHeaderDelegate(this.letter, {this.background});

  final String letter;

  /// Painted behind the letter. Defaults to the scaffold colour, which is right
  /// when the list sits directly on the page.
  final Color? background;

  @override
  double get minExtent => kContactHeaderHeight;
  @override
  double get maxExtent => kContactHeaderHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final theme = Theme.of(context);
    return Container(
      height: kContactHeaderHeight,
      width: double.infinity,
      alignment: AlignmentDirectional.centerStart,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      color: background ?? theme.scaffoldBackgroundColor,
      child: Text(
        // Grey, not tinted — Google Contacts keeps its alphabet letters neutral
        // and reserves the primary colour for settings headings.
        letter,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(ContactSectionHeaderDelegate old) =>
      old.letter != letter || old.background != background;
}

/// The fast-scroll alphabet bar.
class ContactAlphabetBar extends StatelessWidget {
  const ContactAlphabetBar({
    super.key,
    required this.letters,
    required this.available,
    required this.onSelect,
    required this.onInteract,
    required this.onInteractEnd,
  });

  final List<String> letters;

  /// Letters that actually have a section — the rest are shown dimmed.
  final Set<String> available;
  final ValueChanged<String> onSelect;

  /// Called while the bar is being touched / dragged, and once the gesture ends,
  /// so the owner can keep it visible for the duration.
  final VoidCallback onInteract;
  final VoidCallback onInteractEnd;

  @override
  Widget build(BuildContext context) {
    if (letters.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        void handle(Offset local) {
          final h = constraints.maxHeight;
          if (h <= 0) return;
          final i = (local.dy / h * letters.length).floor().clamp(
            0,
            letters.length - 1,
          );
          onSelect(letters[i]);
        }

        // Distribute the letters over the FULL bar height (one Expanded slot
        // each) instead of packing them at line-height — the breathing room
        // between glyphs is whatever the slot leaves around the text, so the
        // index stays legible on any screen. The glyph itself takes ~60% of its
        // slot; the Persian alphabet (33 entries) simply gets slightly smaller
        // slots than Latin (27).
        final slot = constraints.maxHeight / letters.length;
        final fontSize = slot.isFinite ? (slot * 0.62).clamp(8.0, 13.0) : 12.0;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            onInteract();
            handle(d.localPosition);
          },
          onTapUp: (_) => onInteractEnd(),
          onTapCancel: onInteractEnd,
          onVerticalDragStart: (_) => onInteract(),
          onVerticalDragUpdate: (d) {
            onInteract();
            handle(d.localPosition);
          },
          onVerticalDragEnd: (_) => onInteractEnd(),
          onVerticalDragCancel: onInteractEnd,
          child: SizedBox(
            width: 24,
            height: constraints.maxHeight,
            child: Column(
              children: [
                for (final l in letters)
                  Expanded(
                    child: Center(
                      child: Text(
                        l,
                        style: TextStyle(
                          fontSize: fontSize,
                          height: 1,
                          fontWeight: FontWeight.w600,
                          color: available.contains(l)
                              ? theme.colorScheme.primary
                              : theme.colorScheme.primary.withValues(
                                  alpha: 0.3,
                                ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Shows / hides the alphabet bar in step with the list's movement — Google
/// Contacts reveals its index only while the list is moving, so the letters never
/// sit on top of a resting list.
///
/// A mixin rather than a widget: the visibility has to be readable by the
/// `Stack` that positions the bar *and* driven by scroll notifications from
/// inside it, and threading both through a wrapper widget is more code than the
/// three members it would hide.
mixin AlphabetBarVisibility<T extends StatefulWidget> on State<T> {
  bool indexVisible = false;
  Timer? _hideTimer;

  /// Shows the bar and cancels any pending fade-out.
  void revealIndex() {
    _hideTimer?.cancel();
    if (!indexVisible) setState(() => indexVisible = true);
  }

  /// Fades the bar out shortly after the last scroll / drag.
  void scheduleHideIndex() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => indexVisible = false);
    });
  }

  /// Feeds the visibility from a `NotificationListener<ScrollNotification>`.
  bool onIndexScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification) {
      revealIndex();
    } else if (notification is ScrollEndNotification) {
      scheduleHideIndex();
    }
    return false;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }
}
