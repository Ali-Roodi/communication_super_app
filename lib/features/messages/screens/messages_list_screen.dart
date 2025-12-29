import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/widgets/lock_button.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'conversation_screen.dart';

class MessagesListScreen extends StatefulWidget {
  const MessagesListScreen({super.key});

  @override
  State<MessagesListScreen> createState() => _MessagesListScreenState();
}

class _MessagesListScreenState extends State<MessagesListScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // Load threads once when screen initializes
    context.read<MessageBloc>().add(const LoadThreads());
    // Add lifecycle observer to detect when app resumes
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Refresh messages when app resumes (e.g., after receiving SMS while away)
    if (state == AppLifecycleState.resumed) {
      context.read<MessageBloc>().add(const LoadThreads(forceRefresh: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<MessageBloc, MessageState>(
      listener: (context, state) {
        // Auto-refresh threads when a message is sent or received
        if (state is MessageSent) {
          context.read<MessageBloc>().add(const LoadThreads());
        }
      },
      child: Scaffold(
      appBar: RtlAppBar(
        title: 'پیام نگار قاسم',
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              // Handle search
            },
          ),
          const LockButton(),
        ],
      ),
      body: BlocBuilder<MessageBloc, MessageState>(
        builder: (context, state) {
          if (state is MessageLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (state is MessageError) {
            return Center(child: Text('Error: ${state.message}'));
          }

          if (state is ThreadsLoaded) {
            if (state.threads.isEmpty) {
              return const Center(
                child: Text('No messages'),
              );
            }

            return ListView.builder(
              itemCount: state.threads.length,
              itemBuilder: (context, index) {
                final thread = state.threads[index];
                final displayName = thread.contactName ?? thread.phoneNumber;

                return ListTile(
                  leading: AvatarWidget(name: displayName),
                  title: Text(displayName),
                  subtitle: Text(
                    thread.lastMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        DateFormatter.formatDate(thread.lastMessageTime),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (thread.unreadCount > 0)
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${thread.unreadCount}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ConversationScreen(
                          threadId: thread.threadId,
                          phoneNumber: thread.phoneNumber,
                          contactName: thread.contactName,
                        ),
                      ),
                    );
                  },
                );
              },
            );
          }

          return const SizedBox.shrink();
        },
      ),
      ),
    );
  }
}


