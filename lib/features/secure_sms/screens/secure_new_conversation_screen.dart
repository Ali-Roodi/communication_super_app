import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/hidden/bloc/hidden_bloc.dart';
import 'package:communication_super_app/features/keybank/screens/key_bank_screen.dart';
import 'package:communication_super_app/features/messages/screens/contact_selector_screen.dart';

import '../bloc/secure_messages_bloc.dart';
import '../services/secure_identities.dart';
import 'secure_conversation_screen.dart';
import 'secure_group_edit_screen.dart';

/// «گفتگوی رمز»: pick who to talk to — anyone in the address book, or any
/// mobile number typed by hand. There is no list of members: the first SMS
/// carries our certificate, and a phone with هم‌رسان and a key of a trusted
/// authority answers with its own. Anybody else simply never answers.
class SecureNewConversationScreen extends StatefulWidget {
  const SecureNewConversationScreen({super.key});

  @override
  State<SecureNewConversationScreen> createState() =>
      _SecureNewConversationScreenState();
}

class _SecureNewConversationScreenState
    extends State<SecureNewConversationScreen> {
  final _number = TextEditingController();
  late final SecureMessagesBloc _bloc;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _bloc = context.read<SecureMessagesBloc>()..add(const SecureLoadPeers());
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  void _start(SecurePeer peer) => _bloc.add(SecureStartConversation(peer));

  Future<void> _lookup() async {
    final number = _number.text.trim();
    if (number.isEmpty) return;
    FocusScope.of(context).unfocus();
    _bloc.add(SecureLookupNumber(number));
  }

  /// «انتخاب از مخاطبین»: the app's own contact picker, one person.
  Future<void> _pickContact() async {
    final picked = await Navigator.of(context).push<List<PickedRecipient>>(
      MaterialPageRoute(
        builder: (_) => const ContactSelectorScreen(
          pickOnly: true,
          pickTitle: 'انتخاب مخاطب',
        ),
      ),
    );
    final first = picked?.firstOrNull;
    if (first == null) return;
    _bloc.add(SecureLookupNumber(first.phoneNumber, name: first.name));
  }

  void _choose(List<SecurePeer> ways) {
    final peer = ways.firstOrNull;
    if (peer != null) {
      _start(peer);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _bloc.state.hasCert
              ? 'پیام رمز فقط به شمارهٔ همراه (۰۹…) می‌رود، و نه به شمارهٔ خود شما.'
              : 'اول فایل کلید خود را در «بانک کلید» وارد کنید.',
        ),
      ),
    );
  }

  List<Widget> _hiddenSection(BuildContext context, ColorScheme scheme) {
    final hidden = context.watch<HiddenBloc>().state.contacts;
    final rows = [
      for (final c in hidden)
        for (final n in c.numbers)
          if (n.textable &&
              (_filter.isEmpty ||
                  c.name.contains(_filter) ||
                  n.phone.contains(PersianUtils.toEnglishNumber(_filter))))
            (contact: c, phone: n.phone),
    ];
    if (rows.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        child: Text(
          'دفترچه مخفی',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      ),
      for (final r in rows)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Text(
              PersianUtils.getInitials(r.contact.name),
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ),
          title: Text(r.contact.name),
          subtitle: Text(PersianUtils.displayPhone(r.phone)),
          // «گفتگوی رمز»: encrypted, under the name the user gave them.
          onTap: () =>
              _bloc.add(SecureLookupNumber(r.phone, name: r.contact.name)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: MultiBlocListener(
        listeners: [
          BlocListener<SecureMessagesBloc, SecureMessagesState>(
            listenWhen: (a, b) => a.lookupSeq != b.lookupSeq,
            listener: (context, state) => _choose(state.lookup ?? const []),
          ),
          BlocListener<SecureMessagesBloc, SecureMessagesState>(
            listenWhen: (a, b) =>
                a.startedSeq != b.startedSeq && b.startedPhone != null,
            listener: (context, state) {
              final phone = state.startedPhone!;
              final name =
                  state.conversations
                      .where((c) => c.phone == phone)
                      .firstOrNull
                      ?.name ??
                  phone;
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) =>
                      SecureConversationScreen(phone: phone, name: name),
                ),
              );
            },
          ),
        ],
        child: Scaffold(
          appBar: RtlAppBar(title: 'گفتگوی رمز'),
          body: BlocBuilder<SecureMessagesBloc, SecureMessagesState>(
            builder: (context, state) {
              return ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    leading: CircleAvatar(
                      backgroundColor: scheme.tertiaryContainer,
                      child: Icon(
                        Icons.group_add_outlined,
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                    title: const Text('گروه رمز جدید'),
                    onTap: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => const SecureGroupEditScreen(),
                      ),
                    ),
                  ),
                  ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Icon(
                        Icons.contacts_outlined,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    title: const Text('انتخاب از مخاطبین'),
                    enabled: state.hasCert,
                    onTap: _pickContact,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: TextField(
                      controller: _number,
                      enabled: state.hasCert,
                      // A number, or a hidden contact's name to filter by: a
                      // text keyboard, and no forced direction.
                      keyboardType: TextInputType.text,
                      decoration: InputDecoration(
                        hintText: 'شمارهٔ همراه',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: IconButton(
                          tooltip: 'شروع با این شماره',
                          icon: const Icon(Icons.arrow_forward),
                          onPressed: _lookup,
                        ),
                      ),
                      onChanged: (v) => setState(() => _filter = v.trim()),
                      onSubmitted: (_) => _lookup(),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                    child: Text(
                      // Nobody is listed anywhere: whoever has هم‌رسان and a
                      // key of a trusted authority answers the first SMS.
                      'اگر این شماره هم‌رسانِ دارای کلید سازمانی داشته باشد، '
                      'با اولین پیام کانال امن برقرار می‌شود.',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  ..._hiddenSection(context, scheme),
                  if (!state.hasCert)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                      child: Column(
                        children: [
                          Text(
                            'هنوز فایل کلید شما وارد نشده است.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const KeyBankScreen(),
                              ),
                            ),
                            icon: const Icon(Icons.key_outlined),
                            label: const Text('بانک کلید'),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
