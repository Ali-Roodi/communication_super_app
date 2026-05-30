import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import '../bloc/favorites_bloc.dart';
import '../bloc/favorites_event.dart';
import '../bloc/favorites_state.dart';
import '../models/favorite_model.dart';

/// Favorites (موردعلاقه‌ها) tab — a 2-column grid of starred numbers.
/// Tap a card to call; long-press to remove. The empty state and the "+" card
/// both open a contact picker.
class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocBuilder<FavoritesBloc, FavoritesState>(
        builder: (context, state) {
          if (state is FavoritesLoading || state is FavoritesInitial) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state is FavoritesError) {
            return Center(child: Text('خطا: ${state.message}'));
          }
          final favorites =
              state is FavoritesLoaded ? state.favorites : const <FavoriteModel>[];

          if (favorites.isEmpty) {
            return _EmptyState(onAdd: () => _openPicker(context));
          }

          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.95,
            ),
            itemCount: favorites.length + 1,
            itemBuilder: (context, index) {
              if (index == favorites.length) {
                return _AddCard(onTap: () => _openPicker(context));
              }
              return _FavoriteCard(favorite: favorites[index]);
            },
          );
        },
      ),
    );
  }

  Future<void> _openPicker(BuildContext context) {
    final bloc = context.read<FavoritesBloc>();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FavoritePickerSheet(favoritesBloc: bloc),
    );
  }
}

// ── Favorite card ─────────────────────────────────────────────────────────────

class _FavoriteCard extends StatelessWidget {
  final FavoriteModel favorite;
  const _FavoriteCard({required this.favorite});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      color: theme.brightness == Brightness.dark
          ? AppColors.keypadDark
          : AppColors.keypadLight,
      child: InkWell(
        onTap: () =>
            NativeCallService.instance.makeCall(favorite.phoneNumber),
        onLongPress: () => _confirmRemove(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                children: [
                  AvatarWidget(name: favorite.displayName, size: 64),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: AppColors.callAnswerGreen,
                        shape: BoxShape.circle,
                        border: Border.all(color: theme.cardColor, width: 2),
                      ),
                      child: const Icon(Icons.phone,
                          color: Colors.white, size: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                favorite.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmRemove(BuildContext context) {
    final bloc = context.read<FavoritesBloc>();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.call),
                title: const Text('تماس'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  NativeCallService.instance.makeCall(favorite.phoneNumber);
                },
              ),
              ListTile(
                leading: const Icon(Icons.star_outline,
                    color: AppColors.callRejectRed),
                title: const Text(
                  'حذف از موردعلاقه‌ها',
                  style: TextStyle(color: AppColors.callRejectRed),
                ),
                onTap: () {
                  bloc.add(RemoveFavorite(favorite.normalized));
                  Navigator.of(sheetContext).pop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── "Add favorite" card ───────────────────────────────────────────────────────

class _AddCard extends StatelessWidget {
  final VoidCallback onTap;
  const _AddCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      color: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.dividerColor),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 32, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            Text('افزودن موردعلاقه',
                style: TextStyle(color: theme.colorScheme.primary)),
          ],
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_outline,
                size: 96,
                color: theme.colorScheme.primary.withValues(alpha: 0.5)),
            const SizedBox(height: 24),
            Text('مخاطبین موردعلاقه شما اینجا نمایش داده می‌شوند',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('برای دسترسی سریع، مخاطبین پرتماس را به موردعلاقه‌ها اضافه کنید',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: dim)),
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('افزودن موردعلاقه'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Contact picker sheet ──────────────────────────────────────────────────────

class _FavoritePickerSheet extends StatefulWidget {
  final FavoritesBloc favoritesBloc;
  const _FavoritePickerSheet({required this.favoritesBloc});

  @override
  State<_FavoritePickerSheet> createState() => _FavoritePickerSheetState();
}

class _FavoritePickerSheetState extends State<_FavoritePickerSheet> {
  final _repo = ContactRepository();
  late final Future<List<ContactModel>> _contactsFuture;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _contactsFuture = _repo.getAllContacts();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  autofocus: false,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'جستجوی مخاطب',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: FutureBuilder<List<ContactModel>>(
                  future: _contactsFuture,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final q = _query.trim().toLowerCase();
                    final contacts = q.isEmpty
                        ? snapshot.data!
                        : snapshot.data!
                            .where((c) =>
                                c.name.toLowerCase().contains(q) ||
                                c.phoneNumbers.any((p) => p.contains(q)))
                            .toList();
                    if (contacts.isEmpty) {
                      return const Center(child: Text('مخاطبی یافت نشد'));
                    }
                    return ListView.builder(
                      itemCount: contacts.length,
                      itemBuilder: (context, i) {
                        final c = contacts[i];
                        final phone = c.phoneNumbers.isNotEmpty
                            ? c.phoneNumbers.first
                            : c.phoneNumber;
                        return ListTile(
                          leading: c.avatar != null
                              ? CircleAvatar(
                                  backgroundImage: MemoryImage(c.avatar!))
                              : AvatarWidget(name: c.name, size: 40),
                          title: Text(c.name),
                          subtitle: Directionality(
                            textDirection: TextDirection.ltr,
                            child: Text(
                              PersianUtils.toPersianNumber(phone),
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  color: theme.textTheme.bodyMedium?.color),
                            ),
                          ),
                          onTap: () {
                            widget.favoritesBloc.add(AddFavorite(
                              phoneNumber: phone,
                              name: c.name,
                              contactId: c.id,
                            ));
                            Navigator.of(context).pop();
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
