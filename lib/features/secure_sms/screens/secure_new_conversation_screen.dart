import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/keybank/screens/key_bank_screen.dart';

import '../bloc/secure_messages_bloc.dart';
import '../services/secure_identities.dart';
import 'secure_conversation_screen.dart';

/// «گفتگوی رمز»: pick who to talk to. Directory members are listed; a number
/// typed by hand is looked up in the passphrase groups (a group has no member
/// list — any number has a key in it).
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

  /// A number reachable in several ways (a directory and a group, or two
  /// groups): the user picks which key the conversation uses.
  Future<void> _choose(List<SecurePeer> ways) async {
    if (ways.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'برای این شماره کلیدی در بانک کلید نیست. فایل کلید سازمان یا گروه '
            'عبارت عبور مشترک لازم است.',
          ),
        ),
      );
      return;
    }
    if (ways.length == 1) {
      _start(ways.single);
      return;
    }
    final picked = await showModalBottomSheet<SecurePeer>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('با کدام کلید؟', style: TextStyle(fontSize: 16)),
              ),
              for (final w in ways)
                ListTile(
                  leading: Icon(
                    w.source.startsWith('group:')
                        ? Icons.groups_outlined
                        : Icons.menu_book_outlined,
                  ),
                  title: Text(w.name),
                  subtitle: Text(w.sourceName ?? ''),
                  onTap: () => Navigator.of(sheetCtx).pop(w),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked != null) _start(picked);
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
          appBar: const RtlAppBar(title: 'گفتگوی رمز'),
          body: BlocBuilder<SecureMessagesBloc, SecureMessagesState>(
            builder: (context, state) {
              final peers = state.peers
                  .where(
                    (p) =>
                        _filter.isEmpty ||
                        p.name.contains(_filter) ||
                        p.phone.contains(PersianUtils.toEnglishNumber(_filter)),
                  )
                  .toList();
              return ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: TextField(
                      controller: _number,
                      // A name or a number: a text keyboard, and no forced
                      // direction (a Persian name typed LTR reads backwards).
                      keyboardType: TextInputType.text,
                      decoration: InputDecoration(
                        hintText: 'نام یا شماره',
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
                      'برای اعضای گروه‌های عبارت عبور، شماره را کامل وارد کنید.',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (peers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                      child: Text(
                        'اعضای دفترچه‌ها',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  for (final p in peers)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      leading: CircleAvatar(
                        backgroundColor: scheme.primaryContainer,
                        child: Text(
                          PersianUtils.getInitials(p.name),
                          style: TextStyle(color: scheme.onPrimaryContainer),
                        ),
                      ),
                      title: Text(p.name),
                      subtitle: Text(
                        '${PersianUtils.displayPhone(p.phone)} · ${p.sourceName ?? ''}',
                      ),
                      onTap: () => _start(p),
                    ),
                  if (state.peers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                      child: Column(
                        children: [
                          Text(
                            'هنوز دفترچه کلیدی با کلید شما وارد نشده است.',
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
