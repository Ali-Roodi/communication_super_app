import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/infinite_scroll.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure_sms/bloc/secure_messages_bloc.dart';
import 'package:communication_super_app/features/secure_sms/screens/secure_conversation_screen.dart';
import 'package:communication_super_app/features/secure_sms/services/secure_messenger.dart';

import '../bloc/hidden_bloc.dart';
import '../repositories/hidden_contacts_repository.dart';
import 'hidden_calls_screen.dart';
import 'hidden_contact_edit_screen.dart';

/// One hidden contact: their numbers (call / message), note, and calls.
class HiddenContactScreen extends StatelessWidget {
  const HiddenContactScreen({super.key, required this.id});

  final String id;

  /// «پیامک»: the contact's plain-SMS thread.
  void _message(BuildContext context, HiddenContact c, String phone) {
    context.read<SecureMessagesBloc>().add(SecureOpenWith(phone, c.name));
  }

  /// «پیام رمز»: the contact's encrypted conversation — a separate one.
  void _secureMessage(BuildContext context, HiddenContact c, String phone) {
    context.read<SecureMessagesBloc>().add(SecureStartEncrypted(phone, c.name));
  }

  Future<void> _confirmDelete(BuildContext context, HiddenContact c) async {
    final bloc = context.read<HiddenBloc>();
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف از دفترچه مخفی؟'),
          content: Text(
            '«${c.name}» از دفترچه مخفی پاک می‌شود. تماس‌ها و پیامک‌های بعدی '
            'با این شماره‌ها دوباره در سوابق عادی گوشی ثبت می‌شوند؛ سوابقی که '
            'تا امروز در بخش امن است، همان‌جا می‌ماند.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    bloc.add(HiddenDeleteContact(c.id));
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: MultiBlocListener(
        listeners: [
          BlocListener<HiddenBloc, HiddenState>(
            listenWhen: (a, b) => b.status == HiddenStatus.locked,
            listener: (context, _) => Navigator.of(context).pop(),
          ),
          // «پیامک» or «پیام رمز» resolved to its conversation.
          BlocListener<SecureMessagesBloc, SecureMessagesState>(
            listenWhen: (a, b) =>
                a.startedSeq != b.startedSeq && b.startedPhone != null,
            listener: (context, state) {
              final c = context.read<HiddenBloc>().state.contactById(id);
              final phone = state.startedPhone!;
              final number = SecureMessenger.numberOf(phone);
              if (c == null || !c.numbers.any((n) => n.phone == number)) {
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      SecureConversationScreen(phone: phone, name: c.name),
                ),
              );
            },
          ),
        ],
        child: BlocBuilder<HiddenBloc, HiddenState>(
          builder: (context, state) {
            final c = state.contactById(id);
            if (c == null) {
              return const Scaffold(appBar: RtlAppBar(title: ''));
            }
            final phones = [for (final n in c.numbers) n.phone];
            return Scaffold(
              appBar: RtlAppBar(
                title: '',
                actions: [
                  IconButton(
                    tooltip: 'ویرایش',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => HiddenContactEditScreen(contact: c),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'حذف',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmDelete(context, c),
                  ),
                ],
              ),
              body: CustomScrollView(
                slivers: [
                  SliverList.list(
                    children: [
                      const SizedBox(height: 8),
                      Center(
                        child: CircleAvatar(
                          radius: 40,
                          backgroundColor: scheme.primaryContainer,
                          child: Text(
                            PersianUtils.getInitials(c.name),
                            style: TextStyle(
                              fontSize: 28,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          c.name,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.lock,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'دفترچه مخفی',
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      for (final n in c.numbers)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                          leading: const Icon(Icons.phone_outlined),
                          title: Text(
                            PersianUtils.displayPhone(n.phone),
                            textDirection: TextDirection.ltr,
                            textAlign: TextAlign.right,
                          ),
                          subtitle: n.label == null ? null : Text(n.label!),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Encrypted only to a mobile: the handshake is SMS.
                              if (n.phone.startsWith('09'))
                                IconButton(
                                  tooltip: 'پیام رمز',
                                  icon: Icon(
                                    Icons.enhanced_encryption_outlined,
                                    color: scheme.primary,
                                  ),
                                  onPressed: () =>
                                      _secureMessage(context, c, n.phone),
                                ),
                              // A landline cannot receive an SMS.
                              if (n.textable)
                                IconButton(
                                  tooltip: 'پیامک رمزنشده',
                                  icon: Icon(
                                    Icons.message_outlined,
                                    color: scheme.primary,
                                  ),
                                  onPressed: () =>
                                      _message(context, c, n.phone),
                                ),
                              IconButton(
                                tooltip: 'تماس',
                                icon: Icon(
                                  Icons.call_outlined,
                                  color: scheme.primary,
                                ),
                                onPressed: () => placeCall(context, n.phone),
                              ),
                            ],
                          ),
                        ),
                      if (c.note != null) ...[
                        const Divider(height: 24, indent: 16, endIndent: 16),
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                          leading: const Icon(Icons.notes_outlined),
                          title: Text(c.note!),
                        ),
                      ],
                      const Divider(height: 24, indent: 16, endIndent: 16),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                        child: Text(
                          'تماس‌ها',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Read from secure.db a page at a time, not filtered out of
                  // the bloc's own window of the newest calls — that window
                  // need not reach this contact's older calls at all.
                  _ContactCalls(phones: phones, revision: state.calls),
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One hidden contact's calls, newest first, paged as the page scrolls.
/// [revision] is the bloc's call list: when it changes, a call was logged or
/// deleted and the loaded window is read again.
class _ContactCalls extends StatefulWidget {
  const _ContactCalls({required this.phones, required this.revision});

  final List<String> phones;
  final Object revision;

  @override
  State<_ContactCalls> createState() => _ContactCallsState();
}

class _ContactCallsState extends State<_ContactCalls> {
  static const int _page = 30;
  final _repo = HiddenContactsRepository();
  int _window = _page;
  List<HiddenCall>? _calls;
  bool _more = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ContactCalls old) {
    super.didUpdateWidget(old);
    if (!identical(old.revision, widget.revision) ||
        old.phones.join(',') != widget.phones.join(',')) {
      _load();
    }
  }

  Future<void> _load() async {
    if (widget.phones.isEmpty) {
      // Both callers rebuild right after: initState and didUpdateWidget.
      _calls = const [];
      _more = false;
      return;
    }
    _loading = true;
    try {
      final rows = await _repo.calls(phones: widget.phones, limit: _window + 1);
      if (!mounted) return;
      setState(() {
        _more = rows.length > _window;
        _calls = _more ? rows.sublist(0, _window) : rows;
      });
    } catch (e) {
      // Locked meanwhile: the bloc takes the whole screen away.
      debugPrint('Hidden contact calls: ${e.runtimeType}');
      if (mounted) setState(() => _more = false);
    } finally {
      _loading = false;
    }
  }

  void _loadMore() {
    if (_loading || !_more) return;
    _window += _page;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final calls = _calls;
    if (calls == null) return const SliverToBoxAdapter(child: SizedBox());
    if (calls.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
          child: Text(
            'تماسی ثبت نشده است.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return SliverList.builder(
      itemCount: calls.length + (_more ? 1 : 0),
      itemBuilder: (context, i) {
        // the number: whose is clear here
        if (i < calls.length) return HiddenCallTile(call: calls[i]);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadMore();
        });
        return const LoadMoreIndicator();
      },
    );
  }
}
