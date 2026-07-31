import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/widgets/contact_numbers_line.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/contacts/widgets/phone_number_picker.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import '../bloc/search_bloc.dart';
import '../bloc/search_event.dart';
import '../bloc/search_state.dart';

/// Unified search screen (contacts + recent calls). Opened from the AppBar
/// search icon. Uses the globally-provided [SearchBloc].
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
              hintText: 'جستجوی مخاطبین و تماس‌ها',
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
    title: 'مخاطبین و تماس‌ها را جستجو کنید',
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
      leading: AvatarWidget(name: name, size: 40),
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
