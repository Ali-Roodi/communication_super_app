import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/features/call_history/screens/widgets/call_detail_sheet.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_bloc.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_event.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_state.dart';
import 'package:communication_super_app/features/favorites/models/favorite_model.dart';

/// A single row in the recents list (Google Phone style).
///
/// Layout: avatar · [name/number (+ ×N count when collapsed)] over
/// [type-arrow icon · type label · relative time] · 📞 call button.
/// Tapping the row (or the 📞 button) places a call; a long press opens the
/// call detail sheet (activity log + favorite / copy / block / delete).
class CallLogTile extends StatelessWidget {
  final CallLogModel log;

  /// Number of consecutive same-number/same-day calls collapsed into this row.
  final int count;

  /// IDs of *all* calls collapsed into this row. Deleting the row deletes them
  /// all, so a "(۴)" group disappears instead of counting down to "(۳)".
  /// Defaults to just [log]'s id when the row is not collapsed.
  final List<String>? groupIds;

  const CallLogTile({
    super.key,
    required this.log,
    this.count = 1,
    this.groupIds,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasName = log.contactName?.isNotEmpty == true;
    final displayName = hasName
        ? log.contactName!
        : PersianUtils.displayPhone(log.phoneNumber);
    final titleColor = _titleColor(log.callType, theme);

    return InkWell(
      onTap: () => NativeCallService.instance.makeCall(log.phoneNumber),
      onLongPress: () =>
          showCallDetailSheet(context, log, count: count, groupIds: groupIds),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            AvatarWidget(name: displayName, size: 48),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        // A bare number renders LTR so "0919 096 1805" reads
                        // left-to-right like everywhere else; names stay RTL.
                        child: Directionality(
                          textDirection: hasName
                              ? TextDirection.rtl
                              : TextDirection.ltr,
                          child: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color:
                                  titleColor ?? theme.textTheme.bodyLarge?.color,
                            ),
                          ),
                        ),
                      ),
                      if (count > 1)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                            '(${PersianUtils.toPersianNumber('$count')})',
                            style: TextStyle(
                              fontSize: 14,
                              color:
                                  titleColor ??
                                  theme.textTheme.bodyMedium?.color,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  _Subtitle(log: log, theme: theme),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.call),
              iconSize: 22,
              color: AppColors.outgoingCall,
              tooltip: 'تماس',
              onPressed: () =>
                  NativeCallService.instance.makeCall(log.phoneNumber),
            ),
          ],
        ),
      ),
    );
  }

}

// ── Favorite toggle (shared by the options sheet and the detail sheet) ────────

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

// ── Subtitle row: type-arrow icon · type label · relative time ────────────────

class _Subtitle extends StatelessWidget {
  final CallLogModel log;
  final ThemeData theme;

  const _Subtitle({required this.log, required this.theme});

  @override
  Widget build(BuildContext context) {
    final color = theme.textTheme.bodyMedium?.color;
    final text =
        '${_callLabel(log.callType)} · ${_relativeTime(log.timestamp)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              _callIcon(log.callType),
              size: 16,
              color: _callColor(log.callType),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: color),
              ),
            ),
          ],
        ),
        // SIM badge on its own line in the accent colour (Figma 627:4073).
        if (log.simSlot != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'SIM${PersianUtils.toPersianNumber('${log.simSlot}')}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ),
      ],
    );
  }
}

// ── Static helpers ────────────────────────────────────────────────────────────

/// Title (name/number) color for "alert" call types; null = default color.
Color? _titleColor(CallType type, ThemeData theme) {
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

Color _callColor(CallType type) {
  switch (type) {
    case CallType.missed:
      return AppColors.missedCallRed;
    case CallType.incoming:
      return AppColors.incomingCall;
    case CallType.outgoing:
      return AppColors.outgoingCall;
    case CallType.rejected:
      return AppColors.rejectedCall;
    case CallType.blocked:
      return AppColors.blockedCall;
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
      return 'تماس بی‌پاسخ';
    case CallType.incoming:
      return 'تماس ورودی';
    case CallType.outgoing:
      return 'تماس خروجی';
    case CallType.rejected:
      return 'رد شده';
    case CallType.blocked:
      return 'مسدود شده';
  }
}

/// Persian relative time: "هم‌اکنون", "۳ دقیقه پیش", "دیروز", "۱۴۰۳/۰۲/۱۵"...
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
