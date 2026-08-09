import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/phone_contact_avatar.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_bloc.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_event.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/features/call_history/screens/widgets/call_detail_sheet.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_bloc.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_event.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_state.dart';
import 'package:communication_super_app/features/favorites/models/favorite_model.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/features/settings/screens/widgets/block_number_dialog.dart';

/// One recents row, rendered as a card in a grouped run — Google Phone's home
/// list.
///
/// Collapsed it shows avatar · name (+ «(۳)» when calls were merged) over
/// type-arrow · call label · time, with a call button at the end. Tapping the
/// row **expands the same card in place** (it does not navigate): the other
/// calls of the group are listed and a set of tonal action rows appears. That
/// inline accordion is the interaction Google Phone uses, so the list never
/// loses its scroll position.
class CallLogTile extends StatelessWidget {
  final CallLogModel log;

  /// Number of consecutive same-number/same-day calls collapsed into this row.
  final int count;

  /// IDs of *all* calls collapsed into this row. Deleting the row deletes them
  /// all, so a «(۴)» group disappears instead of counting down to «(۳)».
  final List<String>? groupIds;

  /// Every call merged into this row, newest first — listed when expanded.
  final List<CallLogModel> groupLogs;

  /// Corner radii for this row's position inside its section run.
  final BorderRadius radius;

  final bool expanded;
  final VoidCallback onToggle;

  const CallLogTile({
    super.key,
    required this.log,
    required this.radius,
    required this.expanded,
    required this.onToggle,
    this.count = 1,
    this.groupIds,
    this.groupLogs = const [],
  });

  bool get _hasName => log.contactName?.isNotEmpty == true;

  String get _displayName =>
      _hasName ? log.contactName! : PersianUtils.displayPhone(log.phoneNumber);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.cardSurface,
      clipBehavior: Clip.antiAlias,
      borderRadius: radius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            onLongPress: () => showCallDetailSheet(
              context,
              log,
              count: count,
              groupIds: groupIds,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                children: [
                  // Contact photo when the number is saved, initials otherwise.
                  // Same 44 dp box either way, so the row height is unchanged.
                  PhoneContactAvatar(
                    phoneNumber: log.phoneNumber,
                    name: _displayName,
                    size: 44,
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: _titleBlock(context)),
                  IconButton(
                    icon: const Icon(Icons.call_outlined),
                    iconSize: 24,
                    color: scheme.onSurfaceVariant,
                    tooltip: 'تماس',
                    onPressed: () =>
                        NativeCallService.instance.makeCall(log.phoneNumber),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? _ExpandedBody(
                    log: log,
                    groupLogs: groupLogs,
                    groupIds: groupIds,
                    hasName: _hasName,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _titleBlock(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final alert = _alertColor(log.callType);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              // A bare number renders LTR so «0919 096 1805» reads
              // left-to-right like everywhere else; names stay RTL.
              child: Directionality(
                textDirection: _hasName
                    ? TextDirection.rtl
                    : TextDirection.ltr,
                child: Text(
                  _displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    color: scheme.onSurface,
                    height: 1.3,
                  ),
                ),
              ),
            ),
            if (count > 1)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 6),
                child: Text(
                  '(${PersianUtils.toPersianNumber('$count')})',
                  style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Icon(
              _callIcon(log.callType),
              size: 16,
              color: alert ?? scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '${_callLabel(log.callType)} • ${_relativeTime(log.timestamp)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: alert ?? scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (log.simSlot != null) ...[
              const SizedBox(width: 6),
              Text(
                'SIM${PersianUtils.toPersianNumber('${log.simSlot}')}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// ── Expanded body ────────────────────────────────────────────────────────────

/// What the card reveals when tapped: the timestamps of the other calls merged
/// into this row, then the tonal action rows.
class _ExpandedBody extends StatelessWidget {
  final CallLogModel log;
  final List<CallLogModel> groupLogs;
  final List<String>? groupIds;
  final bool hasName;

  const _ExpandedBody({
    required this.log,
    required this.groupLogs,
    required this.groupIds,
    required this.hasName,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The representative is already shown collapsed — list the rest.
    final others = groupLogs.length > 1 ? groupLogs.sublist(1) : const [];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final other in others)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Icon(
                    _callIcon(other.callType),
                    size: 15,
                    color: _alertColor(other.callType) ?? scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _relativeTime(other.timestamp),
                    style: TextStyle(
                      fontSize: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _duration(other),
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (others.isNotEmpty) const SizedBox(height: 4),
          TonalActionRow(
            icon: Icons.chat_bubble_outline,
            label: 'پیام',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ConversationScreen.forPhone(
                  log.phoneNumber,
                  contactName: log.contactName,
                ),
              ),
            ),
          ),
          const SizedBox(height: GroupRadius.gap),
          TonalActionRow(
            icon: Icons.history,
            label: 'سابقه',
            onTap: () => showCallDetailSheet(
              context,
              log,
              count: groupLogs.isEmpty ? 1 : groupLogs.length,
              groupIds: groupIds,
            ),
          ),
          const SizedBox(height: GroupRadius.gap),
          if (!hasName)
            _AddContactRow(phone: log.phoneNumber)
          else
            _FavoriteRow(log: log),
          const SizedBox(height: GroupRadius.gap),
          TonalActionRow(
            icon: Icons.block,
            label: 'مسدود کردن و گزارش هرزنامه',
            onTap: () => blockNumberWithConfirm(
              context,
              phoneNumber: log.phoneNumber,
              contactName: hasName ? log.contactName : null,
            ),
          ),
          const SizedBox(height: GroupRadius.gap),
          TonalActionRow(
            icon: Icons.copy_outlined,
            label: 'کپی شماره',
            onTap: () {
              Clipboard.setData(ClipboardData(text: log.phoneNumber));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('شماره کپی شد')));
            },
          ),
          const SizedBox(height: GroupRadius.gap),
          TonalActionRow(
            icon: Icons.delete_outline,
            label: 'حذف',
            foreground: Theme.of(context).colorScheme.error,
            onTap: () => context.read<CallLogBloc>().add(
              DeleteCallLogs(groupIds ?? [log.id]),
            ),
          ),
        ],
      ),
    );
  }
}

/// «افزودن مخاطب» for an unsaved number — refreshes recents once saved so the
/// new name resolves in the list.
class _AddContactRow extends StatelessWidget {
  final String phone;
  const _AddContactRow({required this.phone});

  @override
  Widget build(BuildContext context) {
    return TonalActionRow(
      icon: Icons.person_add_alt,
      label: 'افزودن مخاطب',
      onTap: () async {
        final callLogBloc = context.read<CallLogBloc>();
        final saved = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => AddEditContactScreen(initialPhone: phone),
          ),
        );
        if (saved == true) callLogBloc.add(const RefreshCallLogs());
      },
    );
  }
}

/// Star/unstar row that follows [FavoritesBloc] so its label and icon always
/// match the current state.
class _FavoriteRow extends StatelessWidget {
  final CallLogModel log;
  const _FavoriteRow({required this.log});

  @override
  Widget build(BuildContext context) {
    final norm = FavoriteModel.normalize(log.phoneNumber);
    return BlocBuilder<FavoritesBloc, FavoritesState>(
      builder: (context, state) {
        final isFav =
            state is FavoritesLoaded &&
            state.favorites.any((f) => f.normalized == norm);
        return TonalActionRow(
          icon: isFav ? Icons.star : Icons.star_border,
          label: isFav ? 'حذف از موردعلاقه‌ها' : 'افزودن به موردعلاقه‌ها',
          foreground: isFav ? AppColors.callHoldOrange : null,
          onTap: () {
            final bloc = context.read<FavoritesBloc>();
            if (isFav) {
              bloc.add(RemoveFavorite(norm));
            } else {
              bloc.add(
                AddFavorite(
                  phoneNumber: log.phoneNumber,
                  name: log.contactName,
                  contactId: log.contactId,
                ),
              );
            }
          },
        );
      },
    );
  }
}

// ── Favorite toggle (still used by the call detail sheet) ─────────────────────

/// Star/unstar [phoneNumber]. Rebuilds on [FavoritesBloc] so the label and icon
/// always match the current favorite state.
class FavoriteToggleTile extends StatelessWidget {
  final String phoneNumber;
  final String? name;
  final String? contactId;
  final FavoritesBloc favoritesBloc;

  /// Called with `true` when the number was added, `false` when removed.
  final ValueChanged<bool> onDone;

  const FavoriteToggleTile({
    super.key,
    required this.phoneNumber,
    required this.favoritesBloc,
    required this.onDone,
    this.name,
    this.contactId,
  });

  @override
  Widget build(BuildContext context) {
    final norm = FavoriteModel.normalize(phoneNumber);
    return BlocBuilder<FavoritesBloc, FavoritesState>(
      bloc: favoritesBloc,
      builder: (context, state) {
        final isFav =
            state is FavoritesLoaded &&
            state.favorites.any((f) => f.normalized == norm);
        return ListTile(
          leading: Icon(
            isFav ? Icons.star : Icons.star_border,
            color: isFav ? AppColors.callHoldOrange : null,
          ),
          title: Text(
            isFav ? 'حذف از موردعلاقه‌ها' : 'افزودن به موردعلاقه‌ها',
          ),
          onTap: () {
            if (isFav) {
              favoritesBloc.add(RemoveFavorite(norm));
            } else {
              favoritesBloc.add(
                AddFavorite(
                  phoneNumber: phoneNumber,
                  name: name,
                  contactId: contactId,
                ),
              );
            }
            onDone(!isFav);
          },
        );
      },
    );
  }
}

// ── Static helpers ───────────────────────────────────────────────────────────

/// Colour for "alert" call types (missed / rejected); null = default.
Color? _alertColor(CallType type) {
  switch (type) {
    case CallType.missed:
      return AppColors.missedCallRed;
    case CallType.rejected:
      return AppColors.rejectedCall;
    case CallType.incoming:
    case CallType.outgoing:
    case CallType.blocked:
      return null;
  }
}

IconData _callIcon(CallType type) {
  switch (type) {
    case CallType.missed:
      return Icons.call_missed;
    case CallType.incoming:
      return Icons.call_received;
    case CallType.outgoing:
      return Icons.call_made;
    case CallType.rejected:
      return Icons.call_end;
    case CallType.blocked:
      return Icons.block;
  }
}

String _callLabel(CallType type) {
  switch (type) {
    case CallType.missed:
      return 'بی‌پاسخ';
    case CallType.incoming:
      return 'ورودی';
    case CallType.outgoing:
      return 'خروجی';
    case CallType.rejected:
      return 'رد شده';
    case CallType.blocked:
      return 'مسدود شده';
  }
}

String _duration(CallLogModel log) {
  switch (log.callType) {
    case CallType.missed:
      return 'بی‌پاسخ';
    case CallType.rejected:
      return 'رد شده';
    case CallType.blocked:
      return 'مسدود';
    case CallType.incoming:
    case CallType.outgoing:
      break;
  }
  final s = log.duration ?? 0;
  if (s == 0) return '—';
  final m = s ~/ 60;
  final sec = s % 60;
  if (m == 0) return '${PersianUtils.toPersianNumber('$sec')} ثانیه';
  final ps = PersianUtils.toPersianNumber(sec.toString().padLeft(2, '0'));
  return '${PersianUtils.toPersianNumber('$m')}:$ps';
}

/// Persian relative time: «هم‌اکنون»، «۳ دقیقه پیش»، «دیروز»، «۱۴۰۳/۰۲/۱۵»…
String _relativeTime(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);

  if (diff.inMinutes < 1) return 'هم‌اکنون';
  if (diff.inMinutes < 60) {
    return '${PersianUtils.toPersianNumber('${diff.inMinutes}')} دقیقه پیش';
  }

  final today = DateTime(now.year, now.month, now.day);
  final logDay = DateTime(dt.year, dt.month, dt.day);
  final dayDiff = today.difference(logDay).inDays;

  if (dayDiff == 0) {
    return '${PersianUtils.toPersianNumber('${diff.inHours}')} ساعت پیش';
  }
  if (dayDiff == 1) return 'دیروز';
  if (dayDiff < 7) {
    return '${PersianUtils.toPersianNumber('$dayDiff')} روز پیش';
  }

  return DateFormatter.formatDate(dt);
}
