import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.archive_outlined,
                      size: 56,
                      color: theme.textTheme.bodyMedium?.color?.withValues(
                        alpha: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('گفتگوی بایگانی‌شده‌ای نیست'),
                  ],
                ),
              );
            }
            return ListView.builder(
              itemCount: state.threads.length,
              itemBuilder: (context, i) => _buildRow(context, state.threads[i]),
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
            ),
          ),
        ),
        onLongPress: () => _unarchive(context, thread),
      ),
    );
  }

  void _unarchive(BuildContext context, MessageThread thread) {
    context.read<MessageBloc>().add(
      ArchiveThreads([thread.threadId], archive: false, fromArchivedView: true),
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('از بایگانی خارج شد')));
  }
}
