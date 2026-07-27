import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';

import '../models/message_model.dart';
import '../repositories/message_repository.dart';
import 'conversation_screen.dart';

/// «ستاره‌دار» — every message bookmarked from the conversation's long-press
/// sheet, newest first, across all threads.
///
/// Starring is local metadata (see `MessageModel.isStarred`), so a message that
/// is deleted globally simply stops appearing here.
class StarredMessagesScreen extends StatefulWidget {
  const StarredMessagesScreen({super.key});

  @override
  State<StarredMessagesScreen> createState() => _StarredMessagesScreenState();
}

class _StarredMessagesScreenState extends State<StarredMessagesScreen> {
  final MessageRepository _repository = MessageRepository();

  List<MessageModel>? _messages;

  /// phone → contact name, resolved once for the whole list.
  Map<String, String> _names = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final messages = await _repository.getStarredMessages();
    final names = <String, String>{};
    for (final m in messages) {
      final key = PhoneNormalizer.toThreadId(m.phoneNumber);
      if (key.isEmpty || names.containsKey(key)) continue;
      final contact = await ContactRepository().getContactByPhoneNumber(
        m.phoneNumber,
      );
      if (contact != null && contact.name.isNotEmpty) names[key] = contact.name;
    }
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _names = names;
    });
  }

  String _titleFor(MessageModel m) {
    final key = PhoneNormalizer.toThreadId(m.phoneNumber);
    return _names[key] ??
        PersianUtils.displayPhone(PhoneNormalizer.toNational(m.phoneNumber));
  }

  Future<void> _unstar(MessageModel m) async {
    await _repository.setStarred(m.id, false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final messages = _messages;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'ستاره‌دار'),
        body: messages == null
            ? const Center(child: CircularProgressIndicator())
            : messages.isEmpty
            ? const EmptyState(
                icon: Icons.star_border,
                title: 'پیام ستاره‌داری ندارید',
                subtitle:
                    'در گفتگو، پیام را نگه دارید و «افزودن به ستاره‌دارها» را بزنید',
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                children: [
                  GroupedList(
                    children: [
                      for (final m in messages) _row(context, m),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Widget _row(BuildContext context, MessageModel m) {
    final scheme = Theme.of(context).colorScheme;
    final title = _titleFor(m);
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ConversationScreen(
            threadId: m.threadId,
            phoneNumber: m.phoneNumber,
            contactName: _names[PhoneNormalizer.toThreadId(m.phoneNumber)],
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AvatarWidget(name: title, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        DateFormatter.formatRelative(m.timestamp),
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    m.body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.star),
              color: scheme.primary,
              tooltip: 'حذف از ستاره‌دارها',
              onPressed: () => _unstar(m),
            ),
          ],
        ),
      ),
    );
  }
}
