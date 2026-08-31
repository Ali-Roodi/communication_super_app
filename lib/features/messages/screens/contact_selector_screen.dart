import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_alphabet.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import 'package:communication_super_app/core/utils/sms_address.dart';
import 'package:communication_super_app/core/widgets/contact_index_list.dart';
import 'package:communication_super_app/core/widgets/contact_numbers_line.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/phone_contact_avatar.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_bloc.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_event.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_state.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/services/contact_groups_service.dart';
import 'package:communication_super_app/features/contacts/widgets/phone_number_picker.dart';

import '../bloc/message_bloc.dart';
import '../models/message_group.dart';
import '../models/message_model.dart';
import '../repositories/group_repository.dart';
import 'conversation_screen.dart';

/// One recipient handed back to a caller that only wanted to pick somebody —
/// «هدایت» (forward), which then opens that chat with the forwarded text already
/// in the composer, or sends to each of several people at once.
class PickedRecipient {
  final String phoneNumber;
  final String? name;
  const PickedRecipient({required this.phoneNumber, this.name});
}

/// «گفتگوی جدید» — the screen behind the inbox's «پیام جدید» button, rebuilt on
/// Google Messages' *New conversation* page.
///
/// The shape is Google's, top to bottom: a «به:» recipient field that collects
/// chips, one row to turn the whole list into a group selection, the numbers the
/// user has been talking to recently, then the whole address book in A–Z sections
/// under a fast-scroll bar.
///
/// Three modes, one screen:
/// * default — tapping a row **opens** that conversation.
/// * [pickOnly] — pops with a `List<PickedRecipient>` (forward). A tap picks one
///   and pops immediately (Google's flow); a **long-press** starts a
///   multi-select and «هدایت (۳)» pops all of them.
/// * [pickMembers] — multi-select that pops with `List<GroupMember>` («افزودن
///   اعضا» on the group details page). [excludeNormalized] hides the people who
///   are already in.
///
/// Everything it filters with is the app's one contact matcher
/// (`ContactRepository.matchContacts` → `SearchText`), and everything it orders
/// and buckets by is the app's one alphabet (`core/widgets/contact_index_list`).
/// This screen used to carry its own `toLowerCase().contains` and its own
/// `sortedKeys..sort()`, which is why a contact saved as «+98 912…» could not be
/// found by typing «0912…», «علي» did not find «علی», and پ چ ژ ک گ were
/// scattered through the letters.
class ContactSelectorScreen extends StatefulWidget {
  final bool pickOnly;

  /// Multi-select that returns the picked people instead of opening anything.
  final bool pickMembers;

  /// Canonical keys to leave out of the list — the members a group already has.
  final Set<String> excludeNormalized;

  /// Opens straight into group selection, for «گفتگوی گروهی» reached from
  /// somewhere that has already decided it wants a group.
  final bool startInGroupMode;

  /// Text to open the conversation with already typed — a share (`ACTION_SEND`)
  /// or an `sms:?body=…` intent that named no recipient.
  final String? initialText;

  const ContactSelectorScreen({
    super.key,
    this.pickOnly = false,
    this.pickMembers = false,
    this.excludeNormalized = const {},
    this.startInGroupMode = false,
    this.initialText,
  });

  @override
  State<ContactSelectorScreen> createState() => _ContactSelectorScreenState();
}

class _ContactSelectorScreenState extends State<ContactSelectorScreen>
    with AlphabetBarVisibility {
  /// Recipients picked so far, keyed by canonical number so the same person
  /// cannot be added twice from two differently-formatted numbers.
  final Map<String, GroupMember> _picked = {};

  /// Rows toggle instead of opening a chat.
  late bool _groupMode = widget.startInGroupMode || widget.pickMembers;

  /// A forward that is going to more than one person.
  ///
  /// Entered by **long-pressing** a row, which is this app's one gesture for
  /// starting a multi-select (the inbox, the contacts tab, the drafts board and
  /// the categories list all use it). A plain tap stays what Google Messages'
  /// forward is — one tap, straight into that conversation with the text ready
  /// to edit — so the common case costs nothing and the several-recipient case
  /// is reachable.
  bool _forwardSelecting = false;

  /// Rows are checkboxes right now, whichever mode put them there.
  bool get _selecting => _groupMode || _forwardSelecting;

  /// True while the mode is a multi-select the user can leave («انصراف»).
  bool get _canLeaveGroupMode =>
      !widget.pickMembers && !widget.startInGroupMode;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  /// The applied query. Typing filters the whole address book, so the keystroke
  /// that starts it is debounced — the contacts tab does the same.
  String _query = '';
  Timer? _searchDebounce;

  /// Compiled once; the «ارسال به …» row runs it per applied query.
  static final RegExp _nonDialable = RegExp(r'[^\d+]');

  // ── Memoized derivations ────────────────────────────────────────────────
  //
  // Both walk the whole address book, and build runs on every keystroke, every
  // keyboard inset and every avatar that arrives.

  String? _lastResultQuery;
  List<ContactModel>? _lastResultSource;
  List<ContactModel> _results = const [];

  /// contact id → the number a numeric query matched, resolved once per query
  /// rather than in each row's build.
  Map<String, String> _resultNumbers = const {};

  List<ContactModel>? _lastSectionSource;
  List<String>? _lastSectionLetters;
  List<ContactSection> _sections = const [];

  List<String> get _indexLetters => activeIndexLetters();

  /// Recent conversations, Google's «Suggestions». Read from the inbox the bloc
  /// has already paged in — no query of its own.
  List<MessageThread> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    context.read<ContactBloc>().add(const LoadContacts());
    _suggestions = _readSuggestions();
    // Google Messages opens this page with the recipient field focused: the
    // fastest path to a new message is to start typing a name.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// The four most recent conversations worth starting another message from.
  ///
  /// Two exclusions, both deliberate:
  /// * **Groups** — this is a shortcut to *a person*, and a group already has its
  ///   own row in the inbox the user just came from.
  /// * **Alphanumeric senders** («Snapp», «MissedCalls», bank codes). They are the
  ///   bulk of a real Iranian inbox and none of them can receive a reply, so a
  ///   suggestion list full of them is a list of dead ends. Four digits is the
  ///   same floor the «ارسال به این شماره» row uses.
  List<MessageThread> _readSuggestions() {
    // `lastInbox`, never `state`: this screen is opened from the inbox *and*
    // from inside a conversation («هدایت»), and in the second case the bloc is
    // parked on that conversation's `MessagesLoaded` — asking `state` there
    // answered "no inbox" and the whole «گفتگوهای اخیر» section vanished from
    // the forward picker, which is where it is most useful.
    final state = context.read<MessageBloc>().lastInbox;
    if (state == null) return const [];
    final out = <MessageThread>[];
    for (final thread in state.threads) {
      if (thread.isGroup) continue;
      final digits = SearchText.digits(thread.phoneNumber);
      if (digits.length < 4) continue;
      if (widget.excludeNormalized.contains(
        PhoneNormalizer.toThreadId(thread.phoneNumber),
      )) {
        continue;
      }
      out.add(thread);
      if (out.length == 4) break;
    }
    return out;
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() => _query = '');
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _query = value);
    });
  }

  // ── Filtering & sectioning ──────────────────────────────────────────────

  /// The contacts this picker may list.
  ///
  /// A contact with no number cannot be texted, so — unlike the contacts tab —
  /// they are left out; and in [ContactSelectorScreen.pickMembers] mode the
  /// people already in the group are too.
  List<ContactModel> _selectable(List<ContactModel> contacts) => [
    for (final contact in contacts)
      if (contact.phoneNumbers.isNotEmpty || contact.phoneNumber.isNotEmpty)
        if (!_isExcluded(contact)) contact,
  ];

  bool _isExcluded(ContactModel contact) {
    if (widget.excludeNormalized.isEmpty) return false;
    final numbers = _numbersOf(contact);
    // Excluded only when EVERY number is already in the group: a contact whose
    // second number is not a member is still worth listing.
    return numbers.every(
      (n) => widget.excludeNormalized.contains(PhoneNormalizer.toThreadId(n)),
    );
  }

  static List<String> _numbersOf(ContactModel contact) =>
      contact.phoneNumbers.isNotEmpty
      ? contact.phoneNumbers
      : [contact.phoneNumber];

  List<ContactModel> _getOrBuildResults(List<ContactModel> source) {
    if (_lastResultQuery == _query && identical(_lastResultSource, source)) {
      return _results;
    }
    _lastResultQuery = _query;
    _lastResultSource = source;
    // The one matcher the contacts tab, the dialer and the message search share:
    // digits match a number in every equivalent form (`+98…` ≡ `0…` ≡ `98…` ≡
    // `9…`), text matches the name with Persian folding.
    _results = ContactRepository.matchContacts(source, _query);

    _resultNumbers = {};
    _typedNumberOwner = null;
    final phoneQuery = PhoneQuery(_query);
    if (!phoneQuery.isEmpty) {
      final typedForms = phoneQuery.needles;
      for (final contact in _results) {
        for (final phone in _numbersOf(contact)) {
          if (phoneQuery.contains(phone)) {
            _resultNumbers[contact.id] = phone;
            if (_typedNumberOwner == null && _isSameNumber(phone, typedForms)) {
              _typedNumberOwner = contact;
            }
            break;
          }
        }
      }
    }
    return _results;
  }

  /// The contact the typed digits **are** — not merely one whose number
  /// contains them.
  ///
  /// Set only when the query and one of the contact's numbers are two spellings
  /// of the same number (`SearchText`'s own equivalence: raw digits, the
  /// national `09…` form, and that form without the trunk `0`, on both sides).
  /// A partial number — `88141859` typed for a landline saved as
  /// `021-881-41859` — deliberately does not count: those digits are a fragment
  /// of the number, not the number.
  ContactModel? _typedNumberOwner;

  /// Whether [stored] and a query already compiled into [typedForms] are the
  /// same number written two ways.
  static bool _isSameNumber(String stored, List<String> typedForms) {
    for (final form in SearchText.phoneForms(stored)) {
      if (typedForms.contains(form)) return true;
    }
    return false;
  }

  List<ContactSection> _getOrBuildSections(List<ContactModel> source) {
    final letters = _indexLetters;
    if (identical(_lastSectionSource, source) &&
        identical(_lastSectionLetters, letters)) {
      return _sections;
    }
    _lastSectionSource = source;
    _lastSectionLetters = letters;
    _sections = buildContactSections(source, letters);
    return _sections;
  }

  // ── Build ───────────────────────────────────────────────────────────────

  String get _title {
    if (widget.pickMembers) return 'افزودن اعضا';
    if (widget.pickOnly) return 'هدایت به';
    return _groupMode ? 'گفتگوی گروهی جدید' : 'گفتگوی جدید';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildHeader(theme),
              if (_groupMode) _buildLabelsAccordion(theme),
              Expanded(
                child: BlocBuilder<ContactBloc, ContactState>(
                  builder: (context, state) {
                    if (state is ContactLoading) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (state is ContactError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'خطا در بارگذاری مخاطبین: ${state.message}',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    if (state is! ContactsLoaded) {
                      return const SizedBox.shrink();
                    }
                    final source = _selectable(state.contacts);
                    return _query.trim().isEmpty
                        ? _buildBrowseList(source, theme)
                        : _buildResultsList(source, theme);
                  },
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: _selecting && _picked.isNotEmpty
            ? Directionality(
                textDirection: TextDirection.rtl,
                child: _buildConfirmBar(theme),
              )
            : null,
      ),
    );
  }

  // ── Header: back + «به:» field with chips ───────────────────────────────

  /// Google Messages' recipient field: the picked people live *inside* the input
  /// as chips, so the field always says who the message is going to and the list
  /// below keeps its full height.
  ///
  /// The chips and the input share one `Wrap`, which is what lets the field grow
  /// a line at a time instead of scrolling the chips out of sight.
  Widget _buildHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'بازگشت',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    // Grows with the chips, then scrolls inside itself — five
                    // rows of chips must not push the contact list off screen.
                    constraints: const BoxConstraints(maxHeight: 132),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'به:',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          for (final entry in _picked.entries)
                            InputChip(
                              key: ValueKey('chip_${entry.key}'),
                              label: Text(entry.value.label),
                              visualDensity: VisualDensity.compact,
                              onDeleted: () =>
                                  setState(() => _picked.remove(entry.key)),
                            ),
                          // The input is sized to what is left of the line, with
                          // a floor so it never collapses to nothing behind a
                          // long chip.
                          SizedBox(
                            width: 180,
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocus,
                              onChanged: _onQueryChanged,
                              textInputAction: TextInputAction.search,
                              style: TextStyle(
                                fontSize: 16,
                                color: scheme.onSurface,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                hintText: _picked.isEmpty
                                    ? 'نام یا شماره تلفن'
                                    : null,
                                hintStyle: TextStyle(
                                  fontSize: 16,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'پاک کردن',
              onPressed: _clearQuery,
            )
          else if ((_groupMode && _canLeaveGroupMode) || _forwardSelecting)
            TextButton(
              onPressed: () => setState(() {
                _groupMode = widget.startInGroupMode || widget.pickMembers;
                _forwardSelecting = false;
                _picked.clear();
                _appliedLabels.clear();
              }),
              child: const Text('انصراف'),
            ),
        ],
      ),
    );
  }

  // ── Bottom confirm bar ──────────────────────────────────────────────────

  /// «ادامه (۳)» — a bottom bar, so picking people never scrolls the button away
  /// and the list keeps its full height.
  Widget _buildConfirmBar(ThemeData theme) {
    final count = PersianUtils.toPersianNumber('${_picked.length}');
    final String label;
    final IconData icon;
    final VoidCallback onPressed;
    if (widget.pickMembers) {
      label = 'افزودن ($count)';
      icon = Icons.person_add_alt;
      onPressed = _returnMembers;
    } else if (_forwardSelecting) {
      label = 'هدایت ($count)';
      icon = Icons.forward;
      onPressed = _returnForwardRecipients;
    } else {
      label = 'ادامه ($count)';
      icon = Icons.arrow_forward;
      onPressed = _startGroup;
    }
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        ),
      ),
    );
  }

  // ── Labels («برچسب‌ها») accordion ────────────────────────────────────────
  //
  // Not a Google Messages feature — an addition, and the reason it earns its
  // place is that a group is nearly always a group the phone already knows
  // about. Picking «همکاران» beats finding nine people by hand, and the labels
  // are collapsed by default so the address book below keeps its height.

  bool _labelsOpen = false;
  bool _labelsLoading = false;
  List<ContactLabel>? _labels;

  /// Labels whose members are currently all in the selection — drawn as picked.
  final Set<String> _appliedLabels = {};

  /// A label whose member ids are being read right now.
  String? _busyLabel;

  Future<void> _toggleLabels() async {
    setState(() => _labelsOpen = !_labelsOpen);
    if (!_labelsOpen || _labels != null || _labelsLoading) return;
    setState(() => _labelsLoading = true);
    final labels = await ContactGroupsService.instance.getLabels();
    if (!mounted) return;
    setState(() {
      _labels = labels;
      _labelsLoading = false;
    });
  }

  Widget _buildLabelsAccordion(ThemeData theme) {
    final scheme = theme.colorScheme;
    final labels = _labels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _toggleLabels,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Icon(
                  Icons.label_outline,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'انتخاب از برچسب‌ها',
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                if (_labelsLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    _labelsOpen ? Icons.expand_less : Icons.expand_more,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
        if (_labelsOpen && labels != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: labels.isEmpty
                ? Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      'برچسبی ساخته نشده است',
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : SizedBox(
                    // Full width, or the parent Column centres the shrink-wrapped
                    // Wrap and the chips float in the middle of an RTL screen.
                    width: double.infinity,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final label in labels)
                          FilterChip(
                            label: Text(label.name),
                            selected: _appliedLabels.contains(label.name),
                            onSelected: _busyLabel != null
                                ? null
                                : (_) => _toggleLabel(label),
                            avatar: _busyLabel == label.name
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : null,
                          ),
                      ],
                    ),
                  ),
          ),
        Divider(height: 1, color: scheme.outlineVariant),
      ],
    );
  }

  /// Adds (or removes) every contact carrying [label] to the selection.
  ///
  /// The label's members are read from the provider's Data table
  /// (`ContactGroupsService.memberIds`) and mapped back onto the loaded contacts
  /// by id; a member with several numbers contributes its first, which is the
  /// same number every other bulk action in the app uses. When the native read
  /// is unavailable the label is simply reported as empty rather than silently
  /// selecting nobody.
  Future<void> _toggleLabel(ContactLabel label) async {
    final state = context.read<ContactBloc>().state;
    if (state is! ContactsLoaded) return;
    setState(() => _busyLabel = label.name);
    final ids = await ContactGroupsService.instance.memberIds(label);
    if (!mounted) return;
    setState(() => _busyLabel = null);

    if (ids == null) {
      _toast('خواندن اعضای «${label.name}» ممکن نشد');
      return;
    }
    final wanted = ids.toSet();
    final members = [
      for (final contact in _selectable(state.contacts))
        if (wanted.contains(contact.id)) contact,
    ];
    if (members.isEmpty) {
      _toast('برچسب «${label.name}» عضوی ندارد');
      return;
    }

    final removing = _appliedLabels.contains(label.name);
    setState(() {
      for (final contact in members) {
        final phone = _numbersOf(contact).first;
        final key = PhoneNormalizer.toThreadId(phone);
        if (key.isEmpty) continue;
        if (removing) {
          _picked.remove(key);
        } else {
          _picked[key] = GroupMember(
            phoneNumber: phone,
            displayName: contact.name,
            contactId: contact.id,
          );
        }
      }
      if (removing) {
        _appliedLabels.remove(label.name);
      } else {
        _appliedLabels.add(label.name);
      }
    });
    // Same reason a single pick clears it: the field's job is done and a stale
    // query hides everybody the label just added.
    if (!removing) _clearQuery();
  }

  // ── Lists ───────────────────────────────────────────────────────────────

  /// The query-less page: «ارسال به …» is impossible here, so it is the group
  /// row, the recent conversations, then the address book.
  Widget _buildBrowseList(List<ContactModel> source, ThemeData theme) {
    final sections = _getOrBuildSections(source);
    final showGroupRow = !_groupMode && !widget.pickOnly && !widget.pickMembers;
    final suggestions = _groupMode ? const <MessageThread>[] : _suggestions;

    // Fixed extents throughout, so the fast-scroll bar can compute where a
    // letter is without laying the list out — the same contract the contacts tab
    // has. Anything added above the sections must be counted here too, or the
    // jump lands short.
    var leading = 0.0;
    if (showGroupRow) leading += kContactRowHeight;
    if (suggestions.isNotEmpty) {
      leading += kContactHeaderHeight + suggestions.length * kContactRowHeight;
    }
    if (sections.isNotEmpty) leading += kContactHeaderHeight;

    final slivers = <Widget>[
      if (showGroupRow) SliverToBoxAdapter(child: _groupRow(theme)),
      if (suggestions.isNotEmpty) ...[
        SliverPersistentHeader(
          pinned: false,
          delegate: ContactSectionHeaderDelegate('گفتگوهای اخیر'),
        ),
        SliverFixedExtentList(
          itemExtent: kContactRowHeight,
          delegate: SliverChildBuilderDelegate(
            (_, i) => _threadRow(suggestions[i]),
            childCount: suggestions.length,
          ),
        ),
      ],
      if (sections.isNotEmpty)
        SliverPersistentHeader(
          pinned: false,
          delegate: ContactSectionHeaderDelegate('همه مخاطبین'),
        ),
      for (final section in sections) ...[
        SliverPersistentHeader(
          pinned: false,
          delegate: ContactSectionHeaderDelegate(section.letter),
        ),
        SliverFixedExtentList(
          itemExtent: kContactRowHeight,
          delegate: SliverChildBuilderDelegate(
            (_, i) => _contactRow(section.contacts[i]),
            childCount: section.contacts.length,
          ),
        ),
      ],
      if (sections.isEmpty && suggestions.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('هیچ مخاطبی یافت نشد')),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 32)),
    ];

    return Stack(
      children: [
        Padding(
          // Reserve the alphabet-bar width at the (RTL) end edge so long names
          // never run underneath the letters while it is showing.
          padding: const EdgeInsetsDirectional.only(end: 24),
          child: NotificationListener<ScrollNotification>(
            onNotification: onIndexScrollNotification,
            child: CustomScrollView(
              controller: _scrollController,
              slivers: slivers,
            ),
          ),
        ),
        if (sections.isNotEmpty)
          Positioned(
            top: 0,
            bottom: 16,
            left: 0, // mirrored to the left edge for the RTL layout
            child: IgnorePointer(
              ignoring: !indexVisible,
              child: AnimatedOpacity(
                opacity: indexVisible ? 1 : 0,
                duration: Duration(milliseconds: indexVisible ? 120 : 320),
                curve: Curves.easeOut,
                child: ContactAlphabetBar(
                  letters: _indexLetters,
                  available: {for (final s in sections) s.letter},
                  onSelect: (letter) => _jumpToLetter(letter, leading),
                  onInteract: revealIndex,
                  onInteractEnd: scheduleHideIndex,
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _jumpToLetter(String letter, double leading) {
    final offset = sectionJumpOffset(
      _sections,
      letter,
      _indexLetters,
      leadingOffset: leading,
    );
    if (offset == null || !_scrollController.hasClients) return;
    _scrollController.animateTo(
      offset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Widget _buildResultsList(List<ContactModel> source, ThemeData theme) {
    final results = _getOrBuildResults(source);
    // «ارسال به این شماره» is for a number that belongs to nobody. When the
    // digits typed ARE a listed contact's number, that contact's own row —
    // right below, named, with the photo — is the answer, and the anonymous row
    // is a trap: it carried the digits exactly as typed, so texting a landline
    // saved as «۰۲۱ ۸۸۱۴ ۱۸۵۹» by typing it without the trunk zero opened an
    // untitled conversation on a *different* thread id than the one the person
    // already has. Google Messages does not offer the row in this case either.
    final sendTo = _typedNumberOwner == null ? _sendToNumber() : null;
    if (results.isEmpty && sendTo == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'نتیجه‌ای برای «${_query.trim()}» یافت نشد',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: results.length + (sendTo == null ? 0 : 1),
      itemBuilder: (_, index) {
        if (sendTo != null && index == 0) return _sendToRow(sendTo, theme);
        final contact = results[index - (sendTo == null ? 0 : 1)];
        return _contactRow(contact, matchedNumber: _resultNumbers[contact.id]);
      },
    );
  }

  // ── Rows ────────────────────────────────────────────────────────────────

  /// «شروع گفتگوی گروهی» — one 56 dp row, the way Google Messages spends its
  /// space here. Everything above the list is a tax on the list.
  Widget _groupRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    return SizedBox(
      height: kContactRowHeight,
      child: InkWell(
        onTap: () {
          setState(() => _groupMode = true);
          HapticFeedback.selectionClick();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.group_add_outlined,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'شروع گفتگوی گروهی',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The dialable number typed into the field, or null.
  ///
  /// Four digits is the floor: below that every second keystroke of a *name*
  /// search containing digits would offer to text a number.
  String? _sendToNumber() {
    final digits = _query.replaceAll(_nonDialable, '');
    if (digits.replaceAll('+', '').length < 4) return null;
    return PhoneNormalizer.toNational(digits);
  }

  Widget _sendToRow(String national, ThemeData theme) {
    final scheme = theme.colorScheme;
    final key = PhoneNormalizer.toThreadId(national);
    final picked = _picked.containsKey(key);
    return SizedBox(
      height: kContactRowHeight,
      child: InkWell(
        onTap: () => _selecting
            ? _toggle(GroupMember(phoneNumber: national))
            : _choose(phoneNumber: national),
        onLongPress: widget.pickOnly && !_selecting
            ? () => _startForwardSelection(GroupMember(phoneNumber: national))
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: picked ? scheme.primary : scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  picked ? Icons.check : Icons.message_outlined,
                  size: 20,
                  color: picked
                      ? scheme.onPrimary
                      : scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ارسال به این شماره',
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 3),
                    // LTR: a phone number is left-to-right content, and in an RTL
                    // paragraph a leading «+» lands at the wrong end.
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        PersianUtils.displayPhone(national),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A recent conversation. Saved or not — the point of the section is the
  /// people the user is actually talking to.
  Widget _threadRow(MessageThread thread) {
    final name = thread.contactName?.isNotEmpty == true
        ? thread.contactName!
        : PersianUtils.displayPhone(
            PhoneNormalizer.toNational(thread.phoneNumber),
          );
    final key = PhoneNormalizer.toThreadId(thread.phoneNumber);
    return _PickerRow(
      height: kContactRowHeight,
      name: name,
      numbers: [thread.phoneNumber],
      selected: _picked.containsKey(key),
      selectionMode: _selecting,
      leading: PhoneContactAvatar(
        phoneNumber: thread.phoneNumber,
        name: name,
        size: 44,
      ),
      onTap: () => _selecting
          ? _toggle(
              GroupMember(
                phoneNumber: thread.phoneNumber,
                displayName: thread.contactName,
              ),
            )
          : _choose(phoneNumber: thread.phoneNumber, name: thread.contactName),
      onLongPress: widget.pickOnly && !_selecting
          ? () => _startForwardSelection(
              GroupMember(
                phoneNumber: thread.phoneNumber,
                displayName: thread.contactName,
              ),
            )
          : null,
    );
  }

  Widget _contactRow(ContactModel contact, {String? matchedNumber}) {
    final numbers = _numbersOf(contact);
    final pickedKey = numbers
        .map(PhoneNormalizer.toThreadId)
        .firstWhere(_picked.containsKey, orElse: () => '');
    return _PickerRow(
      height: kContactRowHeight,
      name: contact.name,
      query: _query,
      numbers: numbers,
      matchedNumber: matchedNumber,
      selected: pickedKey.isNotEmpty,
      selectionMode: _selecting,
      leading: LazyContactAvatar(
        contactId: contact.id,
        name: contact.name,
        size: 44,
      ),
      simContact: contact.isSimContact,
      onTap: () => _onContactTap(contact, numbers, pickedKey),
      onLongPress: widget.pickOnly && !_selecting
          ? () async {
              setState(() => _forwardSelecting = true);
              HapticFeedback.mediumImpact();
              await _onContactTap(contact, numbers, '');
              // Nobody ended up picked (the number sheet was dismissed): leave
              // the mode as it was found rather than stranding an empty
              // selection with no bar and no way back but «انصراف».
              if (mounted && _picked.isEmpty) {
                setState(() => _forwardSelecting = false);
              }
            }
          : null,
    );
  }

  /// Long-press on a row of the forward picker: start selecting, with that row
  /// as the first pick.
  void _startForwardSelection(GroupMember member) {
    HapticFeedback.mediumImpact();
    setState(() => _forwardSelecting = true);
    _toggle(member);
  }

  /// A message goes to **one** number, so a contact with several asks which — in
  /// group mode too, since that is still one number per person.
  Future<void> _onContactTap(
    ContactModel contact,
    List<String> numbers,
    String pickedKey,
  ) async {
    if (_selecting && pickedKey.isNotEmpty) {
      setState(() {
        _picked.remove(pickedKey);
        if (_forwardSelecting && _picked.isEmpty) _forwardSelecting = false;
      });
      return;
    }
    // Numbers already in the group are not offered again.
    final offer = widget.excludeNormalized.isEmpty
        ? numbers
        : [
            for (final n in numbers)
              if (!widget.excludeNormalized.contains(
                PhoneNormalizer.toThreadId(n),
              ))
                n,
          ];
    if (offer.isEmpty) return;
    final chosen = offer.length == 1
        ? offer.first
        : await pickContactNumber(
            context,
            numbers: offer,
            title: 'پیام به ${contact.name}',
          );
    if (chosen == null || !mounted) return;
    if (_selecting) {
      _toggle(
        GroupMember(
          phoneNumber: chosen,
          displayName: contact.name,
          contactId: contact.id,
        ),
      );
    } else {
      _choose(phoneNumber: chosen, name: contact.name);
    }
  }

  void _toggle(GroupMember member) {
    final key = member.normalized;
    if (key.isEmpty) return;
    // An address nothing can be sent to must not become a group member or a
    // forward target: the fan-out would post one permanently-failed message per
    // send. The lists above already keep alphanumeric senders out; this is the
    // guard for a *contact* somebody saved with letters in the number field.
    if (!SmsAddress.canReceive(member.phoneNumber)) {
      _toast('امکان ارسال پیامک به این فرستنده وجود ندارد');
      return;
    }
    HapticFeedback.selectionClick();
    final added = !_picked.containsKey(key);
    setState(() {
      if (_picked.remove(key) == null) _picked[key] = member;
      // A label chip stops reading as applied the moment its members no longer
      // all are — otherwise it looks selected while half the people are gone.
      _appliedLabels.clear();
      // Unpicking the last person leaves the forward selection, the way every
      // other selection bar in the app disappears at zero.
      if (_forwardSelecting && _picked.isEmpty) _forwardSelecting = false;
    });
    // The query answered its question the moment the chip appeared: the person
    // it was looking for is now *in* the field. Leaving the text behind keeps
    // the list filtered to one name, so picking a second person means deleting
    // the first search by hand — and the composing region of the IME survives
    // the rebuild and can commit a stray character into the field. Google
    // Messages clears it on every pick, and so does this.
    if (added) _clearQuery();
  }

  /// Empties the recipient field and the applied query together.
  ///
  /// Both, always: `_query` is the *applied* (debounced) text, so clearing only
  /// the controller would leave the list filtered by a query the field no longer
  /// shows. The pending debounce is cancelled for the same reason.
  void _clearQuery() {
    _searchDebounce?.cancel();
    _searchController.clear();
    if (_query.isNotEmpty) setState(() => _query = '');
  }

  // ── Outcomes ────────────────────────────────────────────────────────────

  /// One recipient: hand it back ([ContactSelectorScreen.pickOnly]) or open the
  /// conversation in place of this screen.
  void _choose({required String phoneNumber, String? name}) {
    if (widget.pickOnly) {
      // Always a list, even for the one-tap case: the caller has a single
      // «هدایت» path to write and a one-element list is the ordinary shape of
      // it. See [_returnForwardRecipients].
      Navigator.pop(context, <PickedRecipient>[
        PickedRecipient(phoneNumber: phoneNumber, name: name),
      ]);
      return;
    }
    // pushReplacement pops this screen off the stack so back returns straight to
    // the inbox rather than to a picker the user is finished with.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ConversationScreen(
          threadId: PhoneNormalizer.toThreadId(phoneNumber),
          phoneNumber: phoneNumber,
          contactName: name,
          initialText: widget.initialText,
        ),
      ),
    );
  }

  void _returnMembers() =>
      Navigator.pop(context, _picked.values.toList(growable: false));

  /// Hands every picked person back to «هدایت», in the order they were picked.
  void _returnForwardRecipients() {
    if (_picked.isEmpty) return;
    Navigator.pop(context, [
      for (final member in _picked.values)
        PickedRecipient(
          phoneNumber: member.phoneNumber,
          name: member.displayName,
        ),
    ]);
  }

  /// Opens the group conversation for the picked people.
  ///
  /// **One recipient is not a group.** Google Messages drops back to the 1:1
  /// conversation, and so does this — a "group" of one would be a second thread
  /// for a person who already has one, with its own history that no other SMS app
  /// on the phone could see.
  ///
  /// Two or more go through `findOrCreate`: picking the same three people twice
  /// must land in the conversation that already exists, or the inbox fills with
  /// rows nothing can tell apart.
  Future<void> _startGroup() async {
    final members = _picked.values.toList(growable: false);
    if (members.isEmpty) return;
    if (members.length == 1) {
      _choose(
        phoneNumber: members.first.phoneNumber,
        name: members.first.displayName,
      );
      return;
    }
    final navigator = Navigator.of(context);
    final group = await GroupRepository().findOrCreate(members: members);
    if (!mounted) return;
    navigator.pushReplacement(
      MaterialPageRoute(
        builder: (_) => ConversationScreen(
          threadId: group.threadId,
          phoneNumber: group.threadId,
          group: group,
          initialText: widget.initialText,
        ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// One row of the picker: avatar (or a check while selecting), name over its
/// numbers.
///
/// Name **and** numbers, at the same 72 dp as the contacts tab: an address book
/// holds several «علی», so a name-only row does not say which one is about to be
/// messaged. The height is a constant the fast-scroll bar's jump offsets are
/// computed from — see `kContactRowHeight`.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.height,
    required this.name,
    required this.numbers,
    required this.leading,
    required this.onTap,
    this.onLongPress,
    this.query = '',
    this.matchedNumber,
    this.selected = false,
    this.selectionMode = false,
    this.simContact = false,
  });

  final double height;
  final String name;
  final List<String> numbers;
  final Widget leading;
  final VoidCallback onTap;

  /// Enters multi-select — the app's one gesture for it, in the inbox, the
  /// contacts tab and here.
  final VoidCallback? onLongPress;

  /// Active search text — the matching run of the name is highlighted the way
  /// Google bolds it, located through the same folding the filter used.
  final String query;
  final String? matchedNumber;
  final bool selected;
  final bool selectionMode;
  final bool simContact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // The avatar always stays: it is how a person is recognised in
                // a list, and replacing it with a tick meant the row lost its
                // face the moment it was picked. The tick belongs in the
                // checkbox on the other end of the row.
                leading,
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (simContact)
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
                        numbers: numbers,
                        matched: matchedNumber,
                        query: SearchText.digits(query),
                      ),
                    ],
                  ),
                ),
                if (selectionMode)
                  selected
                      ? Icon(
                          Icons.check_circle,
                          size: 22,
                          color: scheme.primary,
                        )
                      : Icon(
                          Icons.radio_button_unchecked,
                          size: 22,
                          color: scheme.outline,
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
    // `matchRange` returns indices into the ORIGINAL string — folding drops
    // characters, so an index taken on the folded copy lands on the wrong letter.
    final range = q.isEmpty ? null : SearchText.matchRange(name, q);
    if (range == null) {
      return Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    final (start, end) = range;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: name.substring(0, start), style: base),
          TextSpan(
            text: name.substring(start, end),
            style: base.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(text: name.substring(end), style: base),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
