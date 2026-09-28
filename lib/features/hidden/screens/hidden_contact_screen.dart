import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure_sms/bloc/secure_messages_bloc.dart';
import 'package:communication_super_app/features/secure_sms/screens/secure_conversation_screen.dart';

import '../bloc/hidden_bloc.dart';
import '../repositories/hidden_contacts_repository.dart';
import 'hidden_calls_screen.dart';
import 'hidden_contact_edit_screen.dart';

/// One hidden contact: their numbers (call / message), note, and calls.
class HiddenContactScreen extends StatelessWidget {
  const HiddenContactScreen({super.key, required this.id});

  final String id;

  void _message(BuildContext context, HiddenContact c, String phone) {
    context.read<SecureMessagesBloc>().add(SecureOpenWith(phone, c.name));
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
          // «پیام» resolved to a conversation (encrypted or plain).
          BlocListener<SecureMessagesBloc, SecureMessagesState>(
            listenWhen: (a, b) =>
                a.startedSeq != b.startedSeq && b.startedPhone != null,
            listener: (context, state) {
              final c = context.read<HiddenBloc>().state.contactById(id);
              final phone = state.startedPhone!;
              if (c == null || !c.numbers.any((n) => n.phone == phone)) return;
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
            final phones = {for (final n in c.numbers) n.phone};
            final calls = state.calls
                .where((call) => phones.contains(call.phone))
                .toList();
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
              body: ListView(
                padding: const EdgeInsets.only(bottom: 32),
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
                          // A landline cannot receive an SMS.
                          if (n.textable)
                            IconButton(
                              tooltip: 'پیام',
                              icon: Icon(
                                Icons.message_outlined,
                                color: scheme.primary,
                              ),
                              onPressed: () => _message(context, c, n.phone),
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
                  if (calls.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                      child: Text(
                        'تماسی ثبت نشده است.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  for (final call in calls)
                    HiddenCallTile(
                      call: call,
                    ), // the number: whose is clear here
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
