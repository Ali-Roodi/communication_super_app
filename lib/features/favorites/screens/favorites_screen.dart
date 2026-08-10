import 'package:flutter/material.dart';
import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import 'package:communication_super_app/core/widgets/contact_numbers_line.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/core/widgets/home_search_header.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/contacts/widgets/phone_number_picker.dart';
import '../bloc/favorites_bloc.dart';
import '../bloc/favorites_event.dart';
import '../bloc/favorites_state.dart';
import '../models/favorite_model.dart';

/// Favorites (موردعلاقه‌ها) tab — the circular-avatar grid Google Phone shows
/// under «موارد دلخواه»: a leading «افزودن» circle followed by one circle per
/// starred number, name underneath.
///
/// Tap a favourite to open the saved contact; long-press to remove it.
class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Column(
        children: [
          const HomeSearchHeader(),
          Expanded(
            child: BlocBuilder<FavoritesBloc, FavoritesState>(
              builder: (context, state) {
                if (state is FavoritesLoading || state is FavoritesInitial) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (state is FavoritesError) {
                  return Center(child: Text('خطا: ${state.message}'));
                }
                final favorites = state is FavoritesLoaded
                    ? state.favorites
                    : const <FavoriteModel>[];

                if (favorites.isEmpty) {
                  return _EmptyState(onAdd: () => _openPicker(context));
                }

                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 110),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 0.82,
                      ),
                  itemCount: favorites.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _AddCard(onTap: () => _openPicker(context));
                    }
                    return _FavoriteCard(favorite: favorites[index - 1]);
                  },
                );
              },
            ),
          ),
        ],
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
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      // Tap: open the saved contact. Long-press: the quick-action sheet.
      onTap: () => _openContact(context),
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _showOptions(context);
      },
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _FavoriteAvatar(favorite: favorite),
            const SizedBox(height: 10),
            Text(
              favorite.displayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.3,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tap: resolve the saved device contact and open its detail page. Falls back
  /// to a call when the number isn't a saved contact.
  Future<void> _openContact(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final match = await ContactRepository().getContactByPhoneNumber(
      favorite.phoneNumber,
    );
    if (match != null) {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => DeviceContactDetailScreen(contact: match),
        ),
      );
    } else {
      // Not in the address book — nothing to open; place a call instead.
      messenger.showSnackBar(
        const SnackBar(content: Text('مخاطب ذخیره‌شده‌ای یافت نشد')),
      );
      if (context.mounted) placeCall(context, favorite.phoneNumber);
    }
  }

  /// Long-press: the quick-action sheet Google Phone puts behind a favourite —
  /// call, message, open the contact, and unstar.
  void _showOptions(BuildContext context) {
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
                leading: const Icon(Icons.call_outlined),
                title: const Text('تماس'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  placeCall(context, favorite.phoneNumber);
                },
              ),
              ...simCallRows(
                context,
                favorite.phoneNumber,
                onBeforeCall: () => Navigator.of(sheetContext).pop(),
              ),
              ListTile(
                leading: const Icon(Icons.message_outlined),
                title: const Text('ارسال پیامک'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ConversationScreen.forPhone(
                        favorite.phoneNumber,
                        contactName: favorite.name,
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('مشاهده مخاطب'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openContact(context);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.star_outline,
                  color: AppColors.callRejectRed,
                ),
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

/// The favourite's circle. A favourite stores the contact id it was created
/// from, but older rows (and ones starred from a call log) may not have one —
/// then the id is resolved from the number, so a saved contact's photo shows
/// up either way instead of falling back to initials.
class _FavoriteAvatar extends StatefulWidget {
  final FavoriteModel favorite;
  const _FavoriteAvatar({required this.favorite});

  @override
  State<_FavoriteAvatar> createState() => _FavoriteAvatarState();
}

class _FavoriteAvatarState extends State<_FavoriteAvatar> {
  String? _resolvedId;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_FavoriteAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.favorite.normalized != widget.favorite.normalized) {
      _resolvedId = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    if ((widget.favorite.contactId ?? '').isNotEmpty) return;
    // Backed by the repository's cached number index, so this is a map lookup
    // once the address book is loaded.
    final match = await ContactRepository().getContactByPhoneNumber(
      widget.favorite.phoneNumber,
    );
    if (!mounted || match == null || match.id.isEmpty) return;
    setState(() => _resolvedId = match.id);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.favorite.contactId?.isNotEmpty == true
        ? widget.favorite.contactId!
        : (_resolvedId ?? '');
    return LazyContactAvatar(
      contactId: id,
      name: widget.favorite.displayName,
      size: 72,
    );
  }
}

// ── "Add favorite" card ───────────────────────────────────────────────────────

class _AddCard extends StatelessWidget {
  final VoidCallback onTap;
  const _AddCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.person_add_alt,
                size: 30,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'افزودن',
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
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
    return EmptyState(
      icon: Icons.star_outline,
      title: 'موردعلاقه‌ای ندارید',
      subtitle: 'برای دسترسی سریع، مخاطبین پرتماس را به موردعلاقه‌ها اضافه کنید',
      action: FilledButton.tonalIcon(
        onPressed: onAdd,
        icon: const Icon(Icons.add),
        label: const Text('افزودن موردعلاقه'),
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
                    // A favourite is a number to call, so contacts without one
                    // are not offered here.
                    final reachable = snapshot.data!
                        .where((c) => c.phoneNumbers.isNotEmpty)
                        .toList();
                    // The shared matcher: `+98…` ≡ `0…`, «علي» finds «علی».
                    final contacts = ContactRepository.matchContacts(
                      reachable,
                      _query,
                    );
                    final phoneQuery = PhoneQuery(_query);
                    if (contacts.isEmpty) {
                      return const Center(child: Text('مخاطبی یافت نشد'));
                    }
                    return ListView.builder(
                      itemCount: contacts.length,
                      itemBuilder: (context, i) {
                        final c = contacts[i];
                        // A favourite is one specific number; the subtitle
                        // spells the numbers out (several contacts share a
                        // name) and a contact with more than one asks which on
                        // tap, the way Google Phone does.
                        final phone = c.phoneNumbers.isNotEmpty
                            ? c.phoneNumbers.first
                            : c.phoneNumber;
                        final matched = phoneQuery.isEmpty
                            ? null
                            : c.phoneNumbers.firstWhere(
                                phoneQuery.contains,
                                orElse: () => '',
                              );
                        return ListTile(
                          leading: LazyContactAvatar(
                            contactId: c.id,
                            name: c.name,
                            size: 40,
                          ),
                          title: Text(c.name),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: ContactNumbersLine(
                              numbers: c.phoneNumbers,
                              matched: (matched == null || matched.isEmpty)
                                  ? null
                                  : matched,
                              query: SearchText.digits(_query),
                            ),
                          ),
                          onTap: () async {
                            final picked = await pickContactNumber(
                              context,
                              numbers: c.phoneNumbers.isEmpty
                                  ? [phone]
                                  : c.phoneNumbers,
                              title: 'کدام شماره ${c.name}؟',
                            );
                            if (picked == null || !context.mounted) return;
                            widget.favoritesBloc.add(
                              AddFavorite(
                                phoneNumber: picked,
                                name: c.name,
                                contactId: c.id,
                              ),
                            );
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
