import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import 'package:communication_super_app/core/widgets/contact_numbers_line.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/phone_contact_avatar.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/contacts/widgets/phone_number_picker.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import '../bloc/search_bloc.dart';
import '../bloc/search_event.dart';
import '../bloc/search_state.dart';

/// Unified search screen (contacts + messages + recent calls). Opened from the
/// AppBar search icon. Uses the globally-provided [SearchBloc].
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // Reset any previous query when entering search.
    context.read<SearchBloc>().add(const ClearSearch());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      context.read<SearchBloc>().add(SearchQueryChanged(value));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            decoration: const InputDecoration(
              hintText: 'جستجوی پیام‌ها، مخاطبین و تماس‌ها',
              border: InputBorder.none,
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                context.read<SearchBloc>().add(const ClearSearch());
              },
            ),
          ],
        ),
        body: BlocBuilder<SearchBloc, SearchState>(
          builder: (context, state) {
            if (state is! SearchResults) {
              return _SearchPrompt();
            }
            if (state.isEmpty) {
              // The message section lands a beat after the others, so «نتیجه‌ای
              // یافت نشد» must wait for it — otherwise every query flashes "no
              // results" on its way to showing some.
              if (!state.messagesReady) return const SizedBox.shrink();
              return EmptyState(
                icon: Icons.search_off,
                title: 'نتیجه‌ای یافت نشد',
                subtitle: 'برای «${state.query}» چیزی پیدا نشد',
              );
            }
            // Compiled once for the whole result list, not per row.
            final phoneQuery = PhoneQuery(state.query);
            // Virtualized: a two-letter query can match thousands of contacts,
            // and every eagerly-built row costs an avatar lookup.
            return CustomScrollView(
              slivers: [
                if (state.contacts.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SectionLabel('مخاطبین')),
                  SliverGroupedList(
                    itemCount: state.contacts.length,
                    itemBuilder: (_, i) => _ContactResult(
                      contact: state.contacts[i],
                      query: state.query,
                      phoneQuery: phoneQuery,
                    ),
                  ),
                ],
                if (state.messages.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SectionLabel('پیام‌ها')),
                  SliverGroupedList(
                    itemCount: state.messages.length,
                    itemBuilder: (_, i) => _MessageResult(
                      hit: state.messages[i],
                      query: state.query,
                    ),
                  ),
                ],
                if (state.callLogs.isNotEmpty) ...[
                  const SliverToBoxAdapter(
                    child: SectionLabel('تماس‌های اخیر'),
                  ),
                  SliverGroupedList(
                    itemCount: state.callLogs.length,
                    itemBuilder: (_, i) => _CallLogResult(log: state.callLogs[i]),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            );
          },
        ),
      ),
    );
  }

}

// ── Empty prompt shown before the user types ──────────────────────────────────

class _SearchPrompt extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: Icons.search,
    title: 'پیام‌ها، مخاطبین و تماس‌ها را جستجو کنید',
    subtitle: 'متن پیام‌های فرستاده و دریافت‌شده هم جستجو می‌شود',
  );
}

// ── Contact result → opens detail; trailing call icon dials ───────────────────

class _ContactResult extends StatelessWidget {
  final ContactModel contact;

  /// What was typed — a digit query shows (and dials) the number it matched
  /// rather than the contact's first one.
  final String query;

  /// The typed query compiled once by the list, not per row.
  final PhoneQuery phoneQuery;

  const _ContactResult({
    required this.contact,
    required this.query,
    required this.phoneQuery,
  });

  /// The number the typed digits matched, or null for a name search.
  String? get _matchedNumber {
    if (phoneQuery.isEmpty) return null;
    for (final phone in contact.phoneNumbers) {
      if (phoneQuery.contains(phone)) return phone;
    }
    return null;
  }

  /// A name search on a multi-number contact has no matched number, so the
  /// call button asks which one.
  Future<void> _call(BuildContext context) async {
    final matched = _matchedNumber;
    if (matched == null && contact.phoneNumbers.length > 1) {
      final picked = await pickContactNumber(
        context,
        numbers: contact.phoneNumbers,
        title: 'تماس با ${contact.name}',
      );
      if (picked == null) return;
      await NativeCallService.instance.makeCall(picked);
      return;
    }
    await NativeCallService.instance.makeCall(matched ?? contact.primaryPhone);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: LazyContactAvatar(
        contactId: contact.id,
        name: contact.name,
        size: 40,
      ),
      title: Text(contact.name),
      // Every number, not just the primary one — several contacts share a name
      // and the number is what tells them apart.
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: ContactNumbersLine(
          numbers: contact.phoneNumbers,
          matched: _matchedNumber,
          query: SearchText.digits(query),
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.call, color: AppColors.callAnswerGreen),
        onPressed: () => _call(context),
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DeviceContactDetailScreen(contact: contact),
        ),
      ),
    );
  }
}

// ── Message result → opens the conversation ───────────────────────────────────

class _MessageResult extends StatelessWidget {
  final MessageSearchHit hit;
  final String query;

  const _MessageResult({required this.hit, required this.query});

  /// Characters of the body kept before the match. A hit deep inside a long SMS
  /// is off the end of a one-line preview, so the snippet is windowed on the
  /// match instead of always starting at the body's first character.
  static const int _kLead = 16;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final message = hit.message;
    final title = hit.contactName?.isNotEmpty == true
        ? hit.contactName!
        : PersianUtils.displayPhone(message.phoneNumber);

    return ListTile(
      leading: PhoneContactAvatar(
        phoneNumber: message.phoneNumber,
        name: title,
        size: 40,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            DateFormatter.formatRelative(message.timestamp),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: _snippet(context),
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ConversationScreen.forPhone(
            message.phoneNumber,
            contactName: hit.contactName,
          ),
        ),
      ),
    );
  }

  /// One line of the body with the matched term emphasised, prefixed «شما: » for
  /// a message the user sent — the section deliberately shows both directions,
  /// and the prefix is what tells them apart at a glance.
  Widget _snippet(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    final highlight = base.copyWith(
      color: scheme.primary,
      fontWeight: FontWeight.w700,
    );

    // Flattened FIRST and matched on the flattened copy: `SearchText.matchRange`
    // returns indices into the string it was given, so measuring the range on
    // the raw body and painting the collapsed one would highlight the wrong
    // characters (see CLAUDE.md → «Contact search»).
    final flat = hit.message.body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final range = SearchText.matchRange(flat, query);

    final spans = <TextSpan>[];
    if (hit.message.type == MessageType.sent) {
      spans.add(TextSpan(text: 'شما: ', style: base));
    }

    if (range == null) {
      // A spacing-only match («محمدرضا» in «محمد رضا») has no single range; the
      // row still belongs in the list, just without emphasis.
      spans.add(TextSpan(text: flat, style: base));
    } else {
      var (start, end) = range;
      var text = flat;
      if (start > _kLead + 4) {
        final cut = start - _kLead;
        text = '…${flat.substring(cut)}';
        start -= cut - 1; // the inserted «…» is one character
        end -= cut - 1;
      }
      spans.addAll([
        TextSpan(text: text.substring(0, start), style: base),
        TextSpan(text: text.substring(start, end), style: highlight),
        TextSpan(text: text.substring(end), style: base),
      ]);
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

// ── Call-log result → tapping dials directly ──────────────────────────────────

class _CallLogResult extends StatelessWidget {
  final CallLogModel log;
  const _CallLogResult({required this.log});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = log.contactName?.isNotEmpty == true
        ? log.contactName!
        : PersianUtils.displayPhone(log.phoneNumber);
    return ListTile(
      // Resolves the number to its device contact, so a caller with a photo
      // looks the same here as in the address book (this drew initials only).
      leading: PhoneContactAvatar(
        phoneNumber: log.phoneNumber,
        name: name,
        size: 40,
      ),
      title: Text(name),
      subtitle: Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          PersianUtils.displayPhone(log.phoneNumber),
          textAlign: TextAlign.right,
          style: TextStyle(color: theme.textTheme.bodyMedium?.color),
        ),
      ),
      trailing: const Icon(Icons.call, color: AppColors.callAnswerGreen),
      onTap: () => NativeCallService.instance.makeCall(log.phoneNumber),
    );
  }
}
