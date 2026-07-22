import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../bloc/contact_state.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'add_edit_contact_screen.dart';
import '../models/contact_model.dart';

// Fixed extents so the fast-scroll index bar can compute jump offsets.
const double _kRowHeight = 64;
const double _kHeaderHeight = 32;

// Stock-phone style fast-scroll index. Which alphabet is shown follows the
// device language: Persian phone → Persian letters + '#', otherwise A–Z + '#'.
// '#' is always last and collects every initial outside the active alphabet.
const List<String> _kLatinIndexLetters = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', //
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '#',
];

const List<String> _kPersianIndexLetters = [
  'ا', 'ب', 'پ', 'ت', 'ث', 'ج', 'چ', 'ح', 'خ', 'د', 'ذ', 'ر', 'ز', 'ژ', //
  'س', 'ش', 'ص', 'ض', 'ط', 'ظ', 'ع', 'غ', 'ف', 'ق', 'ک', 'گ', 'ل', 'م', //
  'ن', 'و', 'ه', 'ی', '#',
];

/// Maps the Arabic-script variants a name can start with onto the canonical
/// Persian letter used for its section (e.g. «آرش» and «احمد» both → «ا»).
const Map<String, String> _kPersianLetterAliases = {
  'آ': 'ا', 'أ': 'ا', 'إ': 'ا', 'ٱ': 'ا', 'ء': 'ا', //
  'ك': 'ک',
  'ي': 'ی', 'ى': 'ی', 'ئ': 'ی',
  'ة': 'ه', 'ۀ': 'ه',
  'ؤ': 'و',
};

/// `true` when the device language is Persian, so the contacts index should use
/// the Persian alphabet.
bool isPersianDeviceLocale() =>
    WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'fa';

class ContactsListScreen extends StatefulWidget {
  const ContactsListScreen({super.key});

  @override
  State<ContactsListScreen> createState() => _ContactsListScreenState();
}

class _ContactsListScreenState extends State<ContactsListScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _hasLoaded = false;
  String _query = '';

  // Memoized section grouping (rebuilt only when the contact list or the active
  // alphabet changes).
  List<ContactModel>? _lastContacts;
  List<String>? _lastLetters;
  List<_Section> _sections = [];

  /// Index alphabet for the current device language.
  List<String> get _indexLetters =>
      isPersianDeviceLocale() ? _kPersianIndexLetters : _kLatinIndexLetters;

  List<_Section> _getOrBuildSections(List<ContactModel> contacts) {
    final letters = _indexLetters;
    if (identical(_lastContacts, contacts) &&
        identical(_lastLetters, letters)) {
      return _sections;
    }
    _lastContacts = contacts;
    _lastLetters = letters;
    _sections = _buildSections(contacts, letters);
    return _sections;
  }

  /// Ordering rank of [letter] within the active alphabet ('#' sorts last).
  int _indexRank(String letter) {
    final i = _indexLetters.indexOf(letter);
    return i < 0 ? _indexLetters.length : i;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_hasLoaded) {
        _hasLoaded = true;
        context.read<ContactBloc>().add(const LoadContacts());
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Column(
          children: [
            _buildSearchField(theme),
            Expanded(
              child: BlocBuilder<ContactBloc, ContactState>(
                builder: (context, state) {
                  if (state is ContactLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (state is ContactError) {
                    return Center(child: Text('خطا: ${state.message}'));
                  }
                  if (state is ContactsLoaded) {
                    if (state.contacts.isEmpty) {
                      return _buildEmptyState(theme);
                    }
                    return _query.trim().isEmpty
                        ? _buildSectionedList(
                            _getOrBuildSections(state.contacts),
                            theme,
                          )
                        : _buildSearchResults(state.contacts, theme);
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
        // Extended pill "افزودن مخاطب" per Figma 627:4074.
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'contacts_fab',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AddEditContactScreen()),
          ),
          icon: const Icon(Icons.add),
          label: const Text('افزودن مخاطب'),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      ),
    );
  }

  // ── Search ──────────────────────────────────────────────────────────────

  Widget _buildSearchField(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: 'جستجوی مخاطبین',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          filled: true,
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults(List<ContactModel> contacts, ThemeData theme) {
    final q = _query.trim().toLowerCase();
    final results = contacts
        .where(
          (c) =>
              c.name.toLowerCase().contains(q) ||
              c.phoneNumbers.any((p) => p.contains(q)),
        )
        .toList();
    if (results.isEmpty) {
      return Center(
        child: Text(
          'نتیجه‌ای برای «$_query» یافت نشد',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: results.length,
      itemBuilder: (_, i) => _ContactRow(contact: results[i]),
    );
  }

  // ── Sectioned list with inline headers + fast-scroll bar ──────────────────

  Widget _buildSectionedList(List<_Section> sections, ThemeData theme) {
    final slivers = <Widget>[];
    for (final s in sections) {
      slivers.add(
        // Not pinned: Flutter stacks *every* pinned persistent header at the top
        // as you scroll, which piled the letters up and pushed the list off the
        // screen. Fast navigation is handled by the alphabet bar instead.
        SliverPersistentHeader(
          pinned: false,
          delegate: _SectionHeaderDelegate(s.letter),
        ),
      );
      slivers.add(
        SliverFixedExtentList(
          itemExtent: _kRowHeight,
          delegate: SliverChildBuilderDelegate(
            (_, i) => _ContactRow(contact: s.contacts[i]),
            childCount: s.contacts.length,
          ),
        ),
      );
    }

    return Stack(
      children: [
        // Reserve the alphabet-bar width at the (RTL) end edge so long contact
        // names never run underneath the letters.
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 24),
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              ...slivers,
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          ),
        ),
        Positioned(
          top: 0,
          // Sit a little higher and clear the bottom FAB (which lands at the
          // start/left edge in this RTL layout).
          bottom: 88,
          left: 0, // mirrored to the left edge for the RTL layout
          child: _AlphabetBar(
            letters: _indexLetters,
            available: sections.map((s) => s.letter).toSet(),
            onSelect: _jumpToLetter,
          ),
        ),
      ],
    );
  }

  void _jumpToLetter(String letter) {
    // The bar always shows A–Z + #, but not every letter has a section. Jump to
    // the first section at or after the tapped letter (stock-phone behavior).
    final targetRank = _indexRank(letter);
    var targetIndex = -1;
    var offset = 0.0;
    var acc = 0.0;
    for (var i = 0; i < _sections.length; i++) {
      if (targetIndex == -1 && _indexRank(_sections[i].letter) >= targetRank) {
        targetIndex = i;
        offset = acc;
      }
      acc += _kHeaderHeight + _sections[i].contacts.length * _kRowHeight;
    }
    if (targetIndex == -1) return; // nothing at/after the tapped letter
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      offset.clamp(0.0, max),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  List<_Section> _buildSections(
    List<ContactModel> contacts,
    List<String> letters,
  ) {
    final grouped = <String, List<ContactModel>>{};
    for (final c in contacts) {
      grouped.putIfAbsent(_sectionLetter(c.name, letters), () => []).add(c);
    }
    final keys = grouped.keys.toList()
      ..sort((a, b) => _indexRank(a).compareTo(_indexRank(b)));
    return [for (final k in keys) _Section(k, grouped[k]!)];
  }

  /// Section letter for [name] within the active alphabet [letters]. Latin
  /// initials are uppercased; Persian initials are folded onto their canonical
  /// letter (آ → ا, ك → ک, …). Anything the active alphabet doesn't contain
  /// (digits, symbols, or the *other* script) falls under '#'.
  static String _sectionLetter(String name, List<String> letters) {
    final trimmed = name.trimLeft();
    if (trimmed.isEmpty) return '#';
    final first = trimmed[0];
    final folded = _kPersianLetterAliases[first] ?? first.toUpperCase();
    return letters.contains(folded) && folded != '#' ? folded : '#';
  }

  Widget _buildEmptyState(ThemeData theme) {
    final dim = theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_outline, size: 96, color: dim),
          const SizedBox(height: 16),
          Text('مخاطبی یافت نشد', style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }
}

// ── Section model ─────────────────────────────────────────────────────────────

class _Section {
  final String letter;
  final List<ContactModel> contacts;
  const _Section(this.letter, this.contacts);
}

// ── Sticky section header ─────────────────────────────────────────────────────

class _SectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String letter;
  _SectionHeaderDelegate(this.letter);

  @override
  double get minExtent => _kHeaderHeight;
  @override
  double get maxExtent => _kHeaderHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    return Container(
      height: _kHeaderHeight,
      width: double.infinity,
      alignment: AlignmentDirectional.centerStart,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      color: theme.scaffoldBackgroundColor,
      child: Text(
        // Dim-gray section letters per Figma 627:4074 (not the accent colour).
        letter,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_SectionHeaderDelegate oldDelegate) =>
      oldDelegate.letter != letter;
}

// ── Contact row ───────────────────────────────────────────────────────────────

class _ContactRow extends StatelessWidget {
  final ContactModel contact;
  const _ContactRow({required this.contact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DeviceContactDetailScreen(contact: contact),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            LazyContactAvatar(
              contactId: contact.id,
              name: contact.name,
              size: 48,
            ),
            const SizedBox(width: 16),
            // Name-only rows per Figma 627:4074 (number shows on the detail).
            Expanded(
              child: Text(
                contact.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: theme.textTheme.bodyLarge?.color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Fast-scroll alphabet index bar ────────────────────────────────────────────

class _AlphabetBar extends StatelessWidget {
  final List<String> letters;

  /// Letters that actually have a section — the rest are shown dimmed.
  final Set<String> available;
  final ValueChanged<String> onSelect;

  const _AlphabetBar({
    required this.letters,
    required this.available,
    required this.onSelect,
  });

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
        // index stays legible on any screen. The glyph itself takes ~60% of
        // its slot; the Persian alphabet (33 entries) simply gets slightly
        // smaller slots than Latin (27).
        final slot = constraints.maxHeight / letters.length;
        final fontSize = slot.isFinite ? (slot * 0.62).clamp(8.0, 13.0) : 12.0;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => handle(d.localPosition),
          onVerticalDragUpdate: (d) => handle(d.localPosition),
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
