import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'conversation_screen.dart';
import 'contact_selector_screen.dart';

class MessagesListScreen extends StatefulWidget {
  const MessagesListScreen({super.key});

  @override
  State<MessagesListScreen> createState() => _MessagesListScreenState();
}

class _MessagesListScreenState extends State<MessagesListScreen> with WidgetsBindingObserver {
  bool _hasLoadedInitially = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_hasLoadedInitially) {
        _hasLoadedInitially = true;
        context.read<MessageBloc>().add(const LoadThreads());
      }
    });
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!mounted) return;
    final state = context.read<MessageBloc>().state;
    if (state is! ThreadsLoaded || !state.hasMore) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      context.read<MessageBloc>().add(const LoadMoreThreads());
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Refresh messages when app resumes (e.g., after receiving SMS while away)
    // Only refresh if we've already loaded initially to avoid double-loading
    if (state == AppLifecycleState.resumed && mounted && _hasLoadedInitially) {
      context.read<MessageBloc>().add(const LoadThreads(forceRefresh: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      body: BlocConsumer<MessageBloc, MessageState>(
        listener: (context, state) {
          // No automatic reloading here - let explicit user actions trigger reloads
          // This prevents unwanted state changes while viewing the list
        },
        builder: (context, state) {
          // Handle loading state
          if (state is MessageLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          // Handle error state
          if (state is MessageError) {
            return _buildErrorState(context, state.message, theme);
          }

          // Handle threads loaded state
          if (state is ThreadsLoaded) {
            if (state.threads.isEmpty) {
              return _buildEmptyState(theme);
            }

            return Directionality(
              textDirection: TextDirection.rtl,
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: state.threads.length + (state.hasMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (state.hasMore && index == state.threads.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
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
                  onTap: () async {
                    // Store the bloc reference before async gap
                    final messageBloc = context.read<MessageBloc>();
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ConversationScreen(
                          threadId: thread.threadId,
                          phoneNumber: thread.phoneNumber,
                          contactName: thread.contactName,
                        ),
                      ),
                    );
                    // Reload threads after returning from conversation
                    // to update last message and timestamps
                    if (mounted) {
                      messageBloc.add(const LoadThreads());
                    }
                  },
                );
              },
            ));
          }

          // For any other state (MessagesLoaded, MessageInitial, etc.)
          // Show loading and let the initial load handle it
          if (state is MessagesLoaded) {
            // We're in conversation view state, but shouldn't be here on list screen
            // This is expected after sending a message - just show loading
            return const Center(child: CircularProgressIndicator());
          }

          // Initial state - load threads
          if (state is MessageInitial) {
            return const Center(child: CircularProgressIndicator());
          }

          // Unexpected state - show loading
          return const Center(child: CircularProgressIndicator());
        },
      ),
      floatingActionButton: Directionality(
        textDirection: TextDirection.rtl,
        child: FloatingActionButton(
          heroTag: 'messages_fab', // Unique hero tag to avoid conflicts
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const ContactSelectorScreen(),
              ),
            );
          },
          backgroundColor: const Color(0xFFC3E7FF),
          foregroundColor: const Color(0xFF01579B),
          elevation: 6,
          child: const Icon(Icons.add, size: 28),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
    );
  }

  Widget _buildErrorState(BuildContext context, String errorMessage, ThemeData theme) {
    return Container(
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'خطا در بارگذاری پیام‌ها',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: theme.textTheme.bodyLarge?.color,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              errorMessage,
              style: TextStyle(
                fontSize: 14,
                color: theme.textTheme.bodyMedium?.color,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                context.read<MessageBloc>().add(const LoadThreads(forceRefresh: true));
              },
              icon: const Icon(Icons.refresh),
              label: const Text('تلاش مجدد'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Container(
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 64,
              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'هیچ پیامکی موجود نیست',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: theme.textTheme.bodyLarge?.color,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'پیام‌های شما در اینجا نمایش داده خواهند شد',
              style: TextStyle(
                fontSize: 14,
                color: theme.textTheme.bodyMedium?.color,
              ),
              textAlign: TextAlign.center,
            ),
          ],
      ),
      ),
    );
  }
}


