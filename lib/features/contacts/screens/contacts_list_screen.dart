import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../bloc/contact_state.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'add_edit_contact_screen.dart';
import '../models/contact_model.dart';

// Fixed extents so the fast-scroll index bar can compute jump offsets.
const double _kRowHeight = 64;
const double _kHeaderHeight = 32;

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

  // Memoized section grouping (rebuilt only when the contact list changes).
  List<ContactModel>? _lastContacts;
  List<_Section> _sections = [];

  List<_Section> _getOrBuildSections(List<ContactModel> contacts) {
    if (identical(_lastContacts, contacts)) return _sections;
    _lastContacts = contacts;
    _sections = _buildSections(contacts);
    return _sections;
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
                            _getOrBuildSections(state.contacts), theme)
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
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.phoneNumbers.any((p) => p.contains(q)))
        .toList();
    if (results.isEmpty) {
      return Center(
        child: Text('نتیجه‌ای برای «$_query» یافت نشد',
            style: theme.textTheme.bodyMedium),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: results.length,
      itemBuilder: (_, i) => _ContactRow(contact: results[i]),
    );
  }

  // ── Sectioned list with sticky headers + fast-scroll bar ──────────────────

  Widget _buildSectionedList(List<_Section> sections, ThemeData theme) {
    final slivers = <Widget>[];
    for (final s in sections) {
      slivers.add(SliverPersistentHeader(
        pinned: true,
        delegate: _SectionHeaderDelegate(s.letter),
      ));
      slivers.add(SliverFixedExtentList(
        itemExtent: _kRowHeight,
        delegate: SliverChildBuilderDelegate(
          (_, i) => _ContactRow(contact: s.contacts[i]),
          childCount: s.contacts.length,
        ),
      ));
    }

    return Stack(
      children: [
        CustomScrollView(
          controller: _scrollController,
          slivers: [
            ...slivers,
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
        Positioned(
          top: 0,
          bottom: 0,
          left: 0, // mirrored to the left edge for the RTL layout
          child: _AlphabetBar(
            letters: sections.map((s) => s.letter).toList(),
            onSelect: _jumpToLetter,
          ),
        ),
      ],
    );
  }

  void _jumpToLetter(String letter) {
    var offset = 0.0;
    for (final s in _sections) {
      if (s.letter == letter) break;
      offset += _kHeaderHeight + s.contacts.length * _kRowHeight;
    }
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      offset.clamp(0.0, max),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  List<_Section> _buildSections(List<ContactModel> contacts) {
    final grouped = <String, List<ContactModel>>{};
    for (final c in contacts) {
      grouped.putIfAbsent(_sectionLetter(c.name), () => []).add(c);
    }
    final keys = grouped.keys.toList()..sort();
    return [for (final k in keys) _Section(k, grouped[k]!)];
  }

  static String _sectionLetter(String name) {
    if (name.isEmpty) return '#';
    final ch = name[0];
    final code = ch.codeUnitAt(0);
    // Group digits / symbols under '#'.
    final isLetter = (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) ||
        code > 0x600; // Arabic/Persian block and beyond
    return isLetter ? ch.toUpperCase() : '#';
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
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
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
            contact.avatar != null
                ? CircleAvatar(
                    radius: 24, backgroundImage: MemoryImage(contact.avatar!))
                : AvatarWidget(name: contact.name, size: 48),
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
  final ValueChanged<String> onSelect;

  const _AlphabetBar({required this.letters, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    if (letters.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        void handle(Offset local) {
          final h = constraints.maxHeight;
          if (h <= 0) return;
          final i = (local.dy / h * letters.length)
              .floor()
              .clamp(0, letters.length - 1);
          onSelect(letters[i]);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => handle(d.localPosition),
          onVerticalDragUpdate: (d) => handle(d.localPosition),
          child: Container(
            width: 24,
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final l in letters)
                  Text(
                    l,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
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
