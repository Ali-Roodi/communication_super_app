import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as device_contacts;
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../bloc/contact_state.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/contacts/services/contact_extras_service.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_bloc.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_event.dart';
import 'package:communication_super_app/features/settings/screens/settings_screen.dart';
import 'add_edit_contact_screen.dart';
import '../models/contact_model.dart';

// Fixed extents so the fast-scroll index bar can compute jump offsets. A row
// occupies [_kRowHeight]; the card itself is that minus the group gap, so the
// cards of a section read as one run with hairline seams.
const double _kRowHeight = 68;
const double _kHeaderHeight = 44;

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

  /// Typing filters the whole address book, so the keystroke that starts it is
  /// debounced (the dialer does the same) — otherwise every character walks
  /// every contact and rebuilds the list.
  Timer? _searchDebounce;

  // Memoized search results, so a rebuild that isn't a query change (keyboard
  // insets, avatar arriving) doesn't re-filter the book.
  String? _lastResultQuery;
  List<ContactModel>? _lastResultSource;
  List<ContactModel> _results = const [];

  /// The fast-scroll alphabet is transient: it fades in while the list moves
  /// and fades back out a moment after it stops (Google Contacts' behaviour).
  bool _indexVisible = false;
  Timer? _indexHideTimer;

  /// Ids of the multi-selected contacts. Long-pressing a row enters the mode —
  /// Google Contacts has no per-contact long-press sheet, the actions live in
  /// the contextual bar.
  final Set<String> _selected = {};
  bool get _selectionMode => _selected.isNotEmpty;

  /// The rows currently on screen (section list or search results), so
  /// «انتخاب همه» selects what the user is actually looking at.
  List<ContactModel> _visible = const [];

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

  /// Applies a typed query after a short pause.
  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    if (value.isEmpty) {
      setState(() => _query = '');
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _indexHideTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: PopScope(
        // Back leaves the selection first, exactly as the contextual bar's ✕
        // would — it never drops the user out of the tab mid-selection.
        canPop: !_selectionMode,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _clearSelection();
        },
        child: Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          body: Column(
            children: [
              if (_selectionMode)
                _buildSelectionBar(theme)
              else
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
          // Compact tonal «+» — Google Contacts' create button is an icon FAB,
          // not an extended pill. It steps aside while selecting.
          floatingActionButton: _selectionMode
              ? null
              : FloatingActionButton(
                  heroTag: 'contacts_fab',
                  tooltip: 'افزودن مخاطب',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AddEditContactScreen(),
                    ),
                  ),
                  child: const Icon(Icons.add),
                ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        ),
      ),
    );
  }

  // ── Multi-select ────────────────────────────────────────────────────────

  void _toggleSelect(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  /// Selected contacts, in the order they appear on screen.
  List<ContactModel> get _selectedContacts =>
      _visible.where((c) => _selected.contains(c.id)).toList();

  /// The contextual bar Google Contacts swaps in over the search pill: count,
  /// then favourite / share / delete and «انتخاب همه» behind the overflow.
  Widget _buildSelectionBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    final single = _selected.length == 1;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Material(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'لغو انتخاب',
                  onPressed: _clearSelection,
                ),
                Text(
                  PersianUtils.toPersianNumber('${_selected.length}'),
                  style: TextStyle(fontSize: 16, color: scheme.onSurface),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.star_border),
                  tooltip: 'افزودن به موردعلاقه‌ها',
                  onPressed: _favoriteSelected,
                ),
                // The platform share sheet takes one contact at a time, so the
                // action only makes sense for a single selection.
                if (single)
                  IconButton(
                    icon: const Icon(Icons.share_outlined),
                    tooltip: 'اشتراک‌گذاری',
                    onPressed: _shareSelected,
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'حذف',
                  onPressed: _confirmDeleteSelected,
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  position: PopupMenuPosition.under,
                  onSelected: (_) => setState(
                    () => _selected.addAll(_visible.map((c) => c.id)),
                  ),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'all', child: Text('انتخاب همه')),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Stars the selected contacts' first number — the same number the detail
  /// page's star acts on.
  void _favoriteSelected() {
    final bloc = context.read<FavoritesBloc>();
    final targets = _selectedContacts;
    var added = 0;
    for (final c in targets) {
      final phone = c.phoneNumbers.isNotEmpty
          ? c.phoneNumbers.first
          : c.phoneNumber;
      if (phone.isEmpty) continue;
      bloc.add(AddFavorite(phoneNumber: phone, name: c.name, contactId: c.id));
      added++;
    }
    _clearSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? 'شماره‌ای برای افزودن یافت نشد'
              : '${PersianUtils.toPersianNumber('$added')} مخاطب به موردعلاقه‌ها افزوده شد',
        ),
      ),
    );
  }

  Future<void> _shareSelected() async {
    final id = _selected.first;
    _clearSelection();
    final ok = await ContactExtrasService.instance.shareContact(id);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('اشتراک‌گذاری ممکن نبود')));
  }

  /// Deletes the selection from the DEVICE address book (that is the only
  /// store — the local `contacts` table is legacy).
  Future<void> _confirmDeleteSelected() async {
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف مخاطب'),
          content: Text(
            count == 1
                ? 'این مخاطب برای همیشه از مخاطبین گوشی حذف شود؟'
                : '${PersianUtils.toPersianNumber('$count')} مخاطب برای همیشه از مخاطبین گوشی حذف شوند؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final ids = _selected.toList();
    final messenger = ScaffoldMessenger.of(context);
    final contactBloc = context.read<ContactBloc>();
    try {
      final targets = <device_contacts.Contact>[];
      for (final id in ids) {
        final c = await device_contacts.FlutterContacts.getContact(id);
        if (c != null) targets.add(c);
      }
      if (targets.isNotEmpty) {
        await device_contacts.FlutterContacts.deleteContacts(targets);
      }
      ContactRepository().invalidateCache();
      LazyContactAvatar.invalidateCache();
      if (!mounted) return;
      _clearSelection();
      contactBloc.add(const RefreshContacts());
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${PersianUtils.toPersianNumber('${targets.length}')} مخاطب حذف شد',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('حذف ناموفق بود: $e')));
    }
  }

  /// Builds the tap / long-press behaviour every contact row shares: tap opens
  /// the contact (or toggles while selecting), long-press starts the selection.
  Widget _contactRow(ContactModel contact, {String query = ''}) {
    return _ContactRow(
      contact: contact,
      query: query,
      selected: _selected.contains(contact.id),
      onTap: () {
        if (_selectionMode) {
          _toggleSelect(contact.id);
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DeviceContactDetailScreen(contact: contact),
            ),
          );
        }
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _toggleSelect(contact.id);
      },
    );
  }

  // ── Search ──────────────────────────────────────────────────────────────

  /// The 56 px search pill Google Phone puts at the top of its home screens —
  /// same shape as [HomeSearchHeader], but a live filter field rather than a
  /// button, because filtering the address book in place is what this tab is
  /// for.
  Widget _buildSearchField(ThemeData theme) {
    final scheme = theme.colorScheme;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Material(
          color: scheme.cardSurface,
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                const SizedBox(width: 4),
                PopupMenuButton<VoidCallback>(
                  icon: Icon(Icons.menu, color: scheme.onSurface),
                  tooltip: 'گزینه‌های بیشتر',
                  position: PopupMenuPosition.under,
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem<VoidCallback>(
                      value: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ),
                      child: const Text('تنظیمات'),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onQueryChanged,
                    style: TextStyle(fontSize: 16, color: scheme.onSurface),
                    decoration: InputDecoration(
                      hintText: 'جستجوی مخاطبین',
                      isDense: true,
                      filled: false,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
                if (_query.isEmpty)
                  Icon(Icons.search, color: scheme.onSurfaceVariant)
                else
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: scheme.onSurfaceVariant,
                    onPressed: () {
                      _searchDebounce?.cancel();
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                  ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Filters [contacts] by the active query, reusing the previous result when
  /// neither the query nor the source list changed.
  List<ContactModel> _getOrBuildResults(List<ContactModel> contacts) {
    if (_lastResultQuery == _query && identical(_lastResultSource, contacts)) {
      return _results;
    }
    final q = _query.trim().toLowerCase();
    _lastResultQuery = _query;
    _lastResultSource = contacts;
    _results = contacts
        .where(
          (c) =>
              c.name.toLowerCase().contains(q) ||
              c.phoneNumbers.any((p) => p.contains(q)),
        )
        .toList();
    return _results;
  }

  Widget _buildSearchResults(List<ContactModel> contacts, ThemeData theme) {
    final results = _getOrBuildResults(contacts);
    if (results.isEmpty) {
      return Center(
        child: Text(
          'نتیجه‌ای برای «$_query» یافت نشد',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    _visible = results;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 110),
      itemCount: results.length,
      itemBuilder: (_, i) => _contactRow(results[i], query: _query),
    );
  }

  // ── Sectioned list with inline headers + fast-scroll bar ──────────────────

  Widget _buildSectionedList(List<_Section> sections, ThemeData theme) {
    _visible = [for (final s in sections) ...s.contacts];
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
            (_, i) => _contactRow(s.contacts[i]),
            childCount: s.contacts.length,
          ),
        ),
      );
    }

    return Stack(
      children: [
        // Reserve the alphabet-bar width at the (RTL) end edge so long contact
        // names never run underneath the letters while it is showing.
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 24),
          child: NotificationListener<ScrollNotification>(
            // Google reveals its index only while the list is moving, so the
            // letters never sit on top of a resting list.
            onNotification: (n) {
              if (n is ScrollStartNotification ||
                  n is ScrollUpdateNotification) {
                _revealIndex();
              } else if (n is ScrollEndNotification) {
                _scheduleHideIndex();
              }
              return false;
            },
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                ...slivers,
                const SliverToBoxAdapter(child: SizedBox(height: 96)),
              ],
            ),
          ),
        ),
        Positioned(
          top: 0,
          // Sit a little higher and clear the bottom FAB (which lands at the
          // start/left edge in this RTL layout).
          bottom: 88,
          left: 0, // mirrored to the left edge for the RTL layout
          child: IgnorePointer(
            ignoring: !_indexVisible,
            child: AnimatedOpacity(
              opacity: _indexVisible ? 1 : 0,
              duration: Duration(milliseconds: _indexVisible ? 120 : 320),
              curve: Curves.easeOut,
              child: _AlphabetBar(
                letters: _indexLetters,
                available: sections.map((s) => s.letter).toSet(),
                onSelect: _jumpToLetter,
                // Dragging the bar counts as activity, so it doesn't fade out
                // from under the finger.
                onInteract: _revealIndex,
                onInteractEnd: _scheduleHideIndex,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Fast-scroll index visibility ────────────────────────────────────────

  /// Shows the alphabet index and cancels any pending fade-out.
  void _revealIndex() {
    _indexHideTimer?.cancel();
    if (!_indexVisible) setState(() => _indexVisible = true);
  }

  /// Fades the index out shortly after the last scroll/drag.
  void _scheduleHideIndex() {
    _indexHideTimer?.cancel();
    _indexHideTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _indexVisible = false);
    });
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

  Widget _buildEmptyState(ThemeData theme) => const EmptyState(
    icon: Icons.person_outline,
    title: 'مخاطبی یافت نشد',
    subtitle: 'مخاطبین ذخیره‌شده روی گوشی اینجا نمایش داده می‌شوند',
  );
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
      padding: const EdgeInsets.symmetric(horizontal: 24),
      color: theme.scaffoldBackgroundColor,
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
  bool shouldRebuild(_SectionHeaderDelegate oldDelegate) =>
      oldDelegate.letter != letter;
}

// ── Contact row ───────────────────────────────────────────────────────────────

class _ContactRow extends StatelessWidget {
  final ContactModel contact;

  /// Active search text — the matching run of the name is highlighted, the way
  /// Google Contacts bolds it in the primary colour.
  final String query;

  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ContactRow({
    required this.contact,
    required this.onTap,
    required this.onLongPress,
    this.query = '',
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        12,
        0,
        12,
        GroupRadius.gap,
      ),
      child: Material(
        // A selected row is tinted, and its avatar becomes a check — the same
        // treatment the inbox gives a selected conversation.
        color: selected ? scheme.secondaryContainer : scheme.cardSurface,
        clipBehavior: Clip.antiAlias,
        // Google Contacts rounds every row of the list identically — the
        // "big outer / tight inner" run is reserved for settings groups.
        borderRadius: BorderRadius.circular(GroupRadius.outer),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (selected)
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: scheme.primary,
                    child: Icon(Icons.check, color: scheme.onPrimary),
                  )
                else
                  LazyContactAvatar(
                    contactId: contact.id,
                    name: contact.name,
                    size: 44,
                  ),
                const SizedBox(width: 14),
                // Name-only rows, like Google Contacts (the number lives on the
                // detail page).
                Expanded(child: _name(scheme)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _name(ColorScheme scheme) {
    final base = TextStyle(fontSize: 16, color: scheme.onSurface);
    final q = query.trim();
    if (q.isEmpty) {
      return Text(
        contact.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    final start = contact.name.toLowerCase().indexOf(q.toLowerCase());
    if (start < 0) {
      return Text(
        contact.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    final end = start + q.length;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: contact.name.substring(0, start), style: base),
          TextSpan(
            text: contact.name.substring(start, end),
            style: base.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(text: contact.name.substring(end), style: base),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

// ── Fast-scroll alphabet index bar ────────────────────────────────────────────

class _AlphabetBar extends StatelessWidget {
  final List<String> letters;

  /// Letters that actually have a section — the rest are shown dimmed.
  final Set<String> available;
  final ValueChanged<String> onSelect;

  /// Called while the bar is being touched / dragged, and once the gesture
  /// ends, so the owner can keep it visible for the duration.
  final VoidCallback onInteract;
  final VoidCallback onInteractEnd;

  const _AlphabetBar({
    required this.letters,
    required this.available,
    required this.onSelect,
    required this.onInteract,
    required this.onInteractEnd,
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
