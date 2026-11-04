import 'package:communication_super_app/features/secure/widgets/secure_lock_button.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:communication_super_app/features/hidden/widgets/hidden_entries.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as device_contacts;
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../bloc/contact_state.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_alphabet.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import 'package:communication_super_app/core/widgets/contact_index_list.dart';
import 'package:communication_super_app/core/widgets/contact_numbers_line.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/contacts/screens/contact_labels_screen.dart';
import 'package:communication_super_app/features/contacts/screens/duplicate_contacts_screen.dart';
import 'package:communication_super_app/features/contacts/services/contact_extras_service.dart';
import 'package:communication_super_app/features/contacts/services/contact_filters.dart';
import 'package:communication_super_app/features/contacts/services/pinned_contacts.dart';
import 'package:communication_super_app/features/contacts/widgets/contact_filter_bar.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure_sms/bloc/secure_messages_bloc.dart';
import 'package:communication_super_app/features/contacts/services/contact_link_service.dart';
import 'package:communication_super_app/features/contacts/widgets/merge_contacts_dialog.dart';
import 'package:communication_super_app/features/contacts/services/sim_contacts_service.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_bloc.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_event.dart';
import 'package:communication_super_app/features/settings/screens/settings_screen.dart';
import 'add_edit_contact_screen.dart';
import 'contact_import_screen.dart';
import '../models/contact_model.dart';
import '../services/contact_file_service.dart';
import '../widgets/save_target_sheet.dart';

// The row / header extents and the fast-scroll bar live in
// `core/widgets/contact_index_list.dart` — shared with the «پیام جدید» recipient
// picker, which needs the same list. A second copy would mean the jump offsets
// and the list's order could drift apart, and the jump only lands on the right
// name while they agree.

class ContactsListScreen extends StatefulWidget {
  const ContactsListScreen({super.key});

  @override
  State<ContactsListScreen> createState() => _ContactsListScreenState();
}

class _ContactsListScreenState extends State<ContactsListScreen>
    with AlphabetBarVisibility {
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

  /// contact id → the number the (numeric) query matched, for the result rows.
  Map<String, String> _resultNumbers = const {};

  /// Ids of the multi-selected contacts. Long-pressing a row enters the mode —
  /// Google Contacts has no per-contact long-press sheet, the actions live in
  /// the contextual bar.
  final Set<String> _selected = {};
  bool get _selectionMode => _selected.isNotEmpty;

  /// The rows currently on screen (section list or search results), so
  /// «انتخاب همه» selects what the user is actually looking at.
  List<ContactModel> _visible = const [];

  /// The filter chip in use (matrix row 36); null is «همه».
  ContactFilter? _filter;

  /// The selected label's or messenger's contact ids; null while they load
  /// (the list stays whole meanwhile) and for «رمز», which is worked out from
  /// the secure section's conversations on every build.
  Set<String>? _filterIds;

  // Memoized filter result, so the sections are not regrouped on rebuilds
  // that change nothing (the grouping is keyed on the list's identity).
  List<ContactModel>? _filterSource;
  Object? _filterKey;
  List<ContactModel> _filtered = const [];

  // Memoized section grouping (rebuilt only when the contact list or the active
  // alphabet changes).
  List<ContactModel>? _lastContacts;
  List<String>? _lastLetters;
  List<ContactSection> _sections = [];

  /// Index alphabet for the current device language.
  List<String> get _indexLetters => activeIndexLetters();

  List<ContactSection> _getOrBuildSections(List<ContactModel> contacts) {
    final letters = _indexLetters;
    if (identical(_lastContacts, contacts) &&
        identical(_lastLetters, letters)) {
      return _sections;
    }
    _lastContacts = contacts;
    _lastLetters = letters;
    _sections = buildContactSections(contacts, letters);
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
    ContactFilters.instance.revision.addListener(_onFiltersChanged);
    unawaited(ContactFilters.instance.load());
    PinnedContacts.instance.ids.addListener(_onFiltersChanged);
    unawaited(PinnedContacts.instance.load());
  }

  void _onFiltersChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _selectFilter(ContactFilter? filter) async {
    setState(() {
      _filter = filter;
      _filterIds = null;
    });
    await _loadFilterIds();
  }

  /// Fetches the members of the selected label or messenger — again after the
  /// address book changed under it.
  Future<void> _loadFilterIds() async {
    final filter = _filter;
    if (filter == null || filter.kind == ContactFilterKind.secure) return;
    final ids = await ContactFilters.instance.contactIds(filter);
    if (mounted && _filter == filter) setState(() => _filterIds = ids);
  }

  /// [contacts] narrowed to the selected filter. A filter that is no longer
  /// offered (hidden, a label deleted, the secure section locked) is «همه».
  List<ContactModel> _applyFilter(
    List<ContactModel> contacts,
    List<ContactFilter> offered,
    Iterable<String> securePhones,
  ) {
    final filter = _filter;
    if (filter == null || !offered.contains(filter)) return contacts;
    final Set<String>? ids = filter.kind == ContactFilterKind.secure
        ? ContactFilters.secureMembers(contacts, securePhones)
        : _filterIds;
    if (ids == null) return contacts;
    final key = (filter, ids);
    if (identical(_filterSource, contacts) && _filterKey == key) {
      return _filtered;
    }
    _filterSource = contacts;
    _filterKey = key;
    return _filtered = [
      for (final c in contacts)
        if (ids.contains(c.id)) c,
    ];
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
    ContactFilters.instance.revision.removeListener(_onFiltersChanged);
    PinnedContacts.instance.ids.removeListener(_onFiltersChanged);
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    // AlphabetBarVisibility cancels its fade-out timer in its own dispose.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // «رمز» exists only while the secure section is open (matrix rows 3, 36):
    // with the lock closed nothing here hints that encrypted conversations do.
    final secureOpen = context.select<SecureSessionBloc, bool>(
      (b) => b.state.isUnlocked,
    );
    // Joined, so the select compares by value and a secure-state emit that
    // changes no number does not rebuild the address book.
    final securePhones = secureOpen
        ? context
              .select<SecureMessagesBloc, String>(
                (b) => [
                  for (final c in b.state.conversations)
                    if (c.encrypted) c.phone,
                ].join(','),
              )
              .split(',')
              .where((p) => p.isNotEmpty)
        : const <String>[];
    final offered = ContactFilters.instance.visible(secureOpen: secureOpen);

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
              // «دفترچه مخفی» — only while the secure section is open. Above
              // the list, not in it: the fast-scroll offsets stay untouched.
              if (!_selectionMode && _query.trim().isEmpty)
                const HiddenContactsEntry(),
              if (!_selectionMode)
                ContactFilterBar(
                  filters: offered,
                  all: ContactFilters.instance.all(secureOpen: secureOpen),
                  selected: offered.contains(_filter) ? _filter : null,
                  onSelected: _selectFilter,
                ),
              Expanded(
                child: BlocConsumer<ContactBloc, ContactState>(
                  // The address book changed: the labels and messengers, and
                  // who is in the one selected, may have too.
                  listenWhen: (_, current) => current is ContactsLoaded,
                  listener: (_, state) {
                    ContactFilters.instance.load().then(
                      (_) => _loadFilterIds(),
                    );
                    // A pinned contact deleted outside the app. An empty
                    // read (no permission yet) says nothing about the pins.
                    final contacts = (state as ContactsLoaded).contacts;
                    if (contacts.isNotEmpty) {
                      PinnedContacts.instance.retainOnly({
                        for (final c in contacts) c.id,
                      });
                    }
                  },
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
                      final contacts = _applyFilter(
                        state.contacts,
                        offered,
                        securePhones,
                      );
                      if (contacts.isEmpty) {
                        return const EmptyState(
                          icon: Icons.group_off_outlined,
                          title: 'مخاطبی در این گروه نیست',
                        );
                      }
                      return _query.trim().isEmpty
                          ? _buildSectionedList(
                              _getOrBuildSections(contacts),
                              contacts,
                              theme,
                            )
                          : _buildSearchResults(contacts, theme);
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
    final allPinned = _selected.every(PinnedContacts.instance.isPinned);
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
                  icon: Icon(
                    allPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  ),
                  tooltip: allPinned ? 'برداشتن سنجاق' : 'سنجاق کردن',
                  onPressed: _pinSelected,
                ),
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
                // Two or more rows that are the same person. A SIM contact has
                // no ContactsContract row to aggregate, so it can never be part
                // of a link.
                if (_selected.length > 1 &&
                    !_selectedContacts.any((c) => c.isSimContact))
                  IconButton(
                    icon: const Icon(Icons.merge_type),
                    tooltip: 'ادغام',
                    onPressed: _confirmMergeSelected,
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'حذف',
                  onPressed: _confirmDeleteSelected,
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  position: PopupMenuPosition.under,
                  onSelected: (action) {
                    switch (action) {
                      case 'file':
                        _exportContacts(_selectedContacts);
                      case 'copy':
                        _copySelected();
                      default:
                        setState(
                          () => _selected.addAll(_visible.map((c) => c.id)),
                        );
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'all', child: Text('انتخاب همه')),
                    PopupMenuItem(value: 'file', child: Text('ذخیره در فایل')),
                    PopupMenuItem(value: 'copy', child: Text('کپی به…')),
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

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// A modal "working" dialog around [work], which cannot be dismissed: the
  /// write has to finish before the list behind it means anything.
  Future<T> _whileWorking<T>(String text, Future<T> Function() work) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => PopScope(
        canPop: false,
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text),
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      return await work();
    } finally {
      navigator.pop();
    }
  }

  String _withFailed(String done, int failed) => failed == 0
      ? done
      : '$done، ${PersianUtils.toPersianNumber('$failed')} مورد ناموفق';

  /// Writes [contacts] to a `.vcf` file wherever the user chooses, a cloud
  /// drive included.
  Future<void> _exportContacts(List<ContactModel> contacts) async {
    if (contacts.isEmpty) return;
    const service = ContactFileService();
    try {
      final uri = await service.chooseExportFile();
      if (uri == null || !mounted) return;
      final report = await _whileWorking(
        'در حال ساخت فایل…',
        () => service.writeExportFile(uri, contacts),
      );
      if (!mounted) return;
      _clearSelection();
      _snack(
        _withFailed(
          '${PersianUtils.toPersianNumber('${report.done}')} مخاطب در فایل '
          'ذخیره شد',
          report.failed,
        ),
      );
    } on ContactFileException {
      if (mounted) _snack('ذخیره فایل ممکن نشد');
    }
  }

  Future<void> _exportAll() async {
    final contacts = await ContactRepository().getAllContacts();
    if (!mounted) return;
    if (contacts.isEmpty) {
      _snack('مخاطبی برای ذخیره نیست');
      return;
    }
    await _exportContacts(contacts);
  }

  Future<void> _importFromFile() async {
    const service = ContactFileService();
    try {
      final bytes = await service.pickImportFile();
      if (bytes == null || !mounted) return;
      final parsed = await _whileWorking(
        'در حال خواندن فایل…',
        () => service.parse(bytes),
      );
      if (!mounted) return;
      if (parsed.contacts.isEmpty) {
        _snack('در این فایل مخاطبی پیدا نشد');
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ContactImportScreen(
            contacts: parsed.contacts,
            unreadable: parsed.unreadable,
          ),
        ),
      );
    } on ContactFileException catch (e) {
      if (!mounted) return;
      _snack(
        e.failure == ContactFileFailure.tooLarge
            ? 'این فایل بیش از حد بزرگ است'
            : 'خواندن فایل ممکن نشد',
      );
    }
  }

  /// Copies the selection to another account or a SIM. The originals stay.
  Future<void> _copySelected() async {
    const service = ContactFileService();
    final contacts = _selectedContacts;
    final bloc = context.read<ContactBloc>();
    final targets = await service.targets();
    if (!mounted) return;
    final target = await showSaveTargetSheet(context, targets: targets);
    if (target == null || !mounted) return;
    final report = await _whileWorking(
      'در حال کپی مخاطبین…',
      () => service.copy(contacts, target),
    );
    ContactRepository().invalidateCache();
    LazyContactAvatar.invalidateCache();
    if (!mounted) return;
    _clearSelection();
    bloc.add(const RefreshContacts());
    _snack(
      _withFailed(
        '${PersianUtils.toPersianNumber('${report.done}')} مخاطب به '
        '${saveTargetLabel(target)} کپی شد',
        report.failed,
      ),
    );
  }

  /// Pins the selection to the top of the list, or — when every selected
  /// contact is pinned already — unpins it.
  Future<void> _pinSelected() async {
    final ids = _selected.toList();
    final pins = PinnedContacts.instance;
    if (ids.every(pins.isPinned)) {
      _clearSelection();
      await pins.unpin(ids);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (!await pins.pin(ids)) {
      final max = PersianUtils.toPersianNumber('${AppConstants.maxPinned}');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'حداکثر $max مخاطب سنجاق می‌شود؛ اول یکی را از سنجاق بردارید',
          ),
        ),
      );
      return;
    }
    if (mounted) _clearSelection();
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

  /// Links the selection into one contact.
  ///
  /// Nothing is deleted and no field is dropped — see [ContactLinkService] — so
  /// the confirmation says «ادغام» rather than warning about data loss, and the
  /// undo is «جدا کردن» on the contact page.
  Future<void> _confirmMergeSelected() async {
    final targets = _selectedContacts;
    // The dialog also asks which contact's name and photo survive — the one
    // thing a link actually decides.
    final choice = await showMergeContactsDialog(context, contacts: targets);
    if (choice == null || !mounted) return;

    final ids = [for (final c in targets) c.id];
    final messenger = ScaffoldMessenger.of(context);
    final contactBloc = context.read<ContactBloc>();
    final merged = await ContactLinkService.instance.link(
      ids,
      primaryContactId: choice.primaryContactId,
    );
    ContactRepository().invalidateCache();
    LazyContactAvatar.invalidateCache();
    if (!mounted) return;
    _clearSelection();
    contactBloc.add(const RefreshContacts());
    messenger.showSnackBar(
      SnackBar(
        content: Text(merged == null ? 'ادغام ممکن نشد' : 'مخاطبین ادغام شدند'),
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

    final selection = _selectedContacts;
    final messenger = ScaffoldMessenger.of(context);
    final contactBloc = context.read<ContactBloc>();
    final favoritesBloc = context.read<FavoritesBloc>();
    try {
      // Two address books, two delete calls. A SIM contact has no
      // ContactsContract row, so `getContact` on its id returns null and the
      // old loop silently deleted nothing while reporting success.
      var deleted = 0;
      final targets = <device_contacts.Contact>[];
      for (final contact in selection) {
        if (contact.isSimContact) {
          if (await SimContactsService.delete(contact)) deleted++;
          continue;
        }
        final c = await device_contacts.FlutterContacts.getContact(contact.id);
        if (c != null) targets.add(c);
      }
      if (targets.isNotEmpty) {
        // Chunked, because `deleteContacts` is one `applyBatch` with one
        // operation per contact and ContactsProvider2 throws past 500 of them
        // («Too many content provider operations between yield points»). The
        // plugin runs it on a bare `CoroutineScope(Dispatchers.IO)` with no
        // try/catch, so that exception is uncaught on a background thread and
        // takes the whole process down — «انتخاب همه» on a large address book
        // would have crashed the app rather than reporting a failure.
        const chunk = 400;
        for (var i = 0; i < targets.length; i += chunk) {
          await device_contacts.FlutterContacts.deleteContacts(
            targets.sublist(i, math.min(i + chunk, targets.length)),
          );
        }
        deleted += targets.length;
      }
      await PinnedContacts.instance.unpin([for (final c in selection) c.id]);
      // A deleted person leaves «موردعلاقه‌ها» too. The row there is keyed by
      // number and keeps the name it was starred under, so it went on showing
      // a contact that no longer existed (SM A336E, 1405/07/29).
      for (final contact in selection) {
        for (final phone in {contact.phoneNumber, ...contact.phoneNumbers}) {
          if (phone.isEmpty) continue;
          favoritesBloc.add(RemoveFavorite(phone));
        }
      }
      ContactRepository().invalidateCache();
      LazyContactAvatar.invalidateCache();
      if (!mounted) return;
      _clearSelection();
      contactBloc.add(const RefreshContacts());
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${PersianUtils.toPersianNumber('$deleted')} مخاطب حذف شد',
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
  Widget _contactRow(
    ContactModel contact, {
    String query = '',
    String? matchedNumber,
  }) {
    return _ContactRow(
      contact: contact,
      query: query,
      matchedNumber: matchedNumber,
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
                          builder: (_) => const ContactLabelsScreen(),
                        ),
                      ),
                      child: const Text('برچسب‌ها'),
                    ),
                    PopupMenuItem<VoidCallback>(
                      value: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DuplicateContactsScreen(),
                        ),
                      ),
                      child: const Text('مخاطب‌های تکراری'),
                    ),
                    PopupMenuItem<VoidCallback>(
                      value: _exportAll,
                      child: const Text('ذخیره مخاطبین در فایل'),
                    ),
                    PopupMenuItem<VoidCallback>(
                      value: _importFromFile,
                      child: const Text('افزودن مخاطبین از فایل'),
                    ),
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
                // Absent in the commercial edition (matrix row 3).
                SecureLockButton(color: scheme.onSurfaceVariant),
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
    _lastResultQuery = _query;
    _lastResultSource = contacts;
    // Shared with the dialer and the recipient picker: digits match a number in
    // any equivalent form (`+98…` ≡ `0…` ≡ `98…` ≡ `9…`), text matches the name
    // with Persian folding. A raw `contains` used to miss both.
    _results = ContactRepository.matchContacts(contacts, _query);

    // Resolved here, once per query, rather than in each row's build: the rows
    // rebuild on every scroll and every avatar that arrives.
    _resultNumbers = {};
    final phoneQuery = PhoneQuery(_query);
    if (!phoneQuery.isEmpty) {
      for (final contact in _results) {
        for (final phone in contact.phoneNumbers) {
          if (phoneQuery.contains(phone)) {
            _resultNumbers[contact.id] = phone;
            break;
          }
        }
      }
    }
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
      itemBuilder: (_, i) => _contactRow(
        results[i],
        query: _query,
        matchedNumber: _resultNumbers[results[i].id],
      ),
    );
  }

  // ── Sectioned list with inline headers + fast-scroll bar ──────────────────

  /// The pinned contacts among [contacts], in the order they were pinned.
  List<ContactModel> _pinnedOf(List<ContactModel> contacts) {
    final ids = PinnedContacts.instance.ids.value;
    if (ids.isEmpty) return const [];
    final byId = <String, ContactModel>{
      for (final c in contacts)
        if (ids.contains(c.id)) c.id: c,
    };
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// Height of the «سنجاق‌شده» block above the first letter, which every
  /// fast-scroll jump has to step over.
  double _pinnedExtent = 0;

  Widget _buildSectionedList(
    List<ContactSection> sections,
    List<ContactModel> contacts,
    ThemeData theme,
  ) {
    // The pinned rows repeat contacts that are also under their letter, as
    // Google Contacts does with its starred ones; [_visible] lists each once.
    _visible = [for (final s in sections) ...s.contacts];
    final pinned = _pinnedOf(contacts);
    _pinnedExtent = pinned.isEmpty
        ? 0
        : kContactHeaderHeight + pinned.length * kContactRowHeight;
    final slivers = <Widget>[
      if (pinned.isNotEmpty) ...[
        SliverPersistentHeader(
          pinned: false,
          delegate: ContactSectionHeaderDelegate('سنجاق‌شده'),
        ),
        SliverFixedExtentList(
          itemExtent: kContactRowHeight,
          delegate: SliverChildBuilderDelegate(
            (_, i) => _contactRow(pinned[i]),
            childCount: pinned.length,
          ),
        ),
      ],
    ];
    for (final s in sections) {
      slivers.add(
        SliverPersistentHeader(
          pinned: false,
          delegate: ContactSectionHeaderDelegate(s.letter),
        ),
      );
      slivers.add(
        SliverFixedExtentList(
          itemExtent: kContactRowHeight,
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
            onNotification: onIndexScrollNotification,
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
            ignoring: !indexVisible,
            child: AnimatedOpacity(
              opacity: indexVisible ? 1 : 0,
              duration: Duration(milliseconds: indexVisible ? 120 : 320),
              curve: Curves.easeOut,
              child: ContactAlphabetBar(
                letters: _indexLetters,
                available: sections.map((s) => s.letter).toSet(),
                onSelect: _jumpToLetter,
                // Dragging the bar counts as activity, so it doesn't fade out
                // from under the finger.
                onInteract: revealIndex,
                onInteractEnd: scheduleHideIndex,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _jumpToLetter(String letter) {
    final offset = sectionJumpOffset(
      _sections,
      letter,
      _indexLetters,
      leadingOffset: _pinnedExtent,
    );
    if (offset == null) return; // nothing at/after the tapped letter
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      offset.clamp(0.0, max),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Widget _buildEmptyState(ThemeData theme) => const EmptyState(
    icon: Icons.person_outline,
    title: 'مخاطبی یافت نشد',
    subtitle: 'مخاطبین ذخیره‌شده روی گوشی اینجا نمایش داده می‌شوند',
  );
}

// ── Contact row ───────────────────────────────────────────────────────────────

class _ContactRow extends StatelessWidget {
  final ContactModel contact;

  /// Active search text — the matching run of the name is highlighted, the way
  /// Google Contacts bolds it in the primary colour.
  final String query;

  /// The contact's number the (numeric) query matched — resolved by the list,
  /// not here, so a scrolling rebuild never re-runs the match.
  final String? matchedNumber;

  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ContactRow({
    required this.contact,
    required this.onTap,
    required this.onLongPress,
    this.query = '',
    this.matchedNumber,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, GroupRadius.gap),
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
                // Name *and* number. An address book holds several «علی», so a
                // name-only row (what this used to be, with the number left to
                // the detail page) does not say which one you are looking at.
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // A SIM contact reads as an ordinary row apart from a
                      // small card glyph — it behaves differently (no photo,
                      // no editing in place, one number), and the row is where
                      // the user finds that out before tapping.
                      if (contact.isSimContact)
                        Row(
                          children: [
                            Flexible(child: _name(scheme)),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.sim_card_outlined,
                              size: 14,
                              color: scheme.onSurfaceVariant,
                            ),
                          ],
                        )
                      else
                        _name(scheme),
                      const SizedBox(height: 3),
                      ContactNumbersLine(
                        numbers: contact.phoneNumbers,
                        matched: matchedNumber,
                        query: SearchText.digits(query),
                      ),
                    ],
                  ),
                ),
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
    // Located through the same folding the filter uses, so a row matched on
    // «علي» still highlights when the name is stored «علی» (and a row matched
    // by number simply renders unstyled).
    final range = q.isEmpty ? null : SearchText.matchRange(contact.name, q);
    if (range == null) {
      return Text(
        contact.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    final (start, end) = range;
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
