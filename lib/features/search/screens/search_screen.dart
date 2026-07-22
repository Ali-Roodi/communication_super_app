import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
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
              return Center(
                child: Text('نتیجه‌ای برای «${state.query}» یافت نشد'),
              );
            }
            return ListView(
              children: [
                if (state.contacts.isNotEmpty) ...[
                  _header('مخاطبین'),
                  ...state.contacts.map((c) => _ContactResult(contact: c)),
                ],
                if (state.callLogs.isNotEmpty) ...[
                  _header('تماس‌های اخیر'),
                  ...state.callLogs.map((l) => _CallLogResult(log: l)),
                ],
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header(String title) {
    return Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

// ── Empty prompt shown before the user types ──────────────────────────────────

class _SearchPrompt extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(
      context,
    ).textTheme.bodyMedium?.color?.withValues(alpha: 0.5);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search, size: 72, color: dim),
          const SizedBox(height: 12),
          Text(
            'مخاطبین و تماس‌ها را جستجو کنید',
            style: TextStyle(color: dim),
          ),
        ],
      ),
    );
  }
}

// ── Contact result → opens detail; trailing call icon dials ───────────────────

class _ContactResult extends StatelessWidget {
  final ContactModel contact;
  const _ContactResult({required this.contact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: LazyContactAvatar(
        contactId: contact.id,
        name: contact.name,
        size: 40,
      ),
      title: Text(contact.name),
      subtitle: Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          PersianUtils.displayPhone(contact.primaryPhone),
          textAlign: TextAlign.right,
          style: TextStyle(color: theme.textTheme.bodyMedium?.color),
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.call, color: AppColors.callAnswerGreen),
        onPressed: () =>
            NativeCallService.instance.makeCall(contact.primaryPhone),
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
