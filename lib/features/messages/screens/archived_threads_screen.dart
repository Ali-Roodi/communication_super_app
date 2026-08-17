import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/undo_snack_bar.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import '../models/message_model.dart';
import 'conversation_screen.dart';
import 'widgets/thread_tile.dart';

/// Archived conversations. Reuses the global [MessageBloc]; loads the archived
/// inbox on entry and restores the active inbox when popped (handled by the
/// caller). Swipe or the row action un-archives a conversation.
class ArchivedThreadsScreen extends StatefulWidget {
  const ArchivedThreadsScreen({super.key});

  @override
  State<ArchivedThreadsScreen> createState() => _ArchivedThreadsScreenState();
}

class _ArchivedThreadsScreenState extends State<ArchivedThreadsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<MessageBloc>().add(const LoadThreads(archived: true));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('بایگانی')),
        body: BlocBuilder<MessageBloc, MessageState>(
          builder: (context, state) {
            if (state is! ThreadsLoaded || !state.archived) {
              if (state is MessageError) {
                return Center(child: Text(state.message));
              }
              return const Center(child: CircularProgressIndicator());
            }
            if (state.threads.isEmpty) {
              return const EmptyState(
                icon: Icons.archive_outlined,
                title: 'گفتگوی بایگانی‌شده‌ای نیست',
                subtitle: 'گفتگوهایی که بایگانی کنید اینجا نگه داشته می‌شوند',
              );
            }
            // Same rounded sheet the inbox uses, so archived reads as the
            // same surface one level down.
            return Container(
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.cardSurface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: state.threads.length,
                itemBuilder: (context, i) =>
                    _buildRow(context, state.threads[i]),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, MessageThread thread) {
    return Dismissible(
      key: ValueKey('archived_${thread.threadId}'),
      direction: DismissDirection.horizontal,
      confirmDismiss: (_) async {
        _unarchive(context, thread);
        return false;
      },
      background: Container(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
        alignment: AlignmentDirectional.centerStart,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Icons.unarchive_outlined, color: Colors.white),
      ),
      secondaryBackground: Container(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
        alignment: AlignmentDirectional.centerEnd,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Icons.unarchive_outlined, color: Colors.white),
      ),
      child: ThreadTile(
        thread: thread,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ConversationScreen(
              threadId: thread.threadId,
              phoneNumber: thread.phoneNumber,
              contactName: thread.contactName,
              // An archived conversation can be a group too; carried so the
              // header opens named rather than resolving a frame later.
              group: thread.group,
            ),
          ),
        ),
        onLongPress: () => _unarchive(context, thread),
      ),
    );
  }

  void _unarchive(BuildContext context, MessageThread thread) {
    final bloc = context.read<MessageBloc>();
    bloc.add(
      ArchiveThreads([thread.threadId], archive: false, fromArchivedView: true),
    );
    showUndoSnack(
      context,
      message: 'از بایگانی خارج شد',
      onUndo: () => bloc.add(ArchiveThreads([thread.threadId], archive: true)),
    );
  }
}
