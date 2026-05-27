import 'package:flutter/material.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';

/// A single row in the call log list.
///
/// Shows the contact avatar (with a colour-coded call-type badge), name,
/// formatted time + duration, SIM slot, and a callback button.
class CallLogTile extends StatelessWidget {
  final CallLogModel log;

  const CallLogTile({super.key, required this.log});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName = log.contactName?.isNotEmpty == true
        ? log.contactName!
        : log.phoneNumber;
    final isMissed = log.callType == CallType.missed;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: _AvatarWithBadge(
        name: displayName,
        callType: log.callType,
        backgroundColor: theme.scaffoldBackgroundColor,
      ),
      title: Text(
        displayName,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          // Missed calls are shown in red to draw attention
          color: isMissed
              ? AppColors.missedCallRed
              : theme.textTheme.bodyLarge?.color,
        ),
      ),
      subtitle: _Subtitle(log: log, theme: theme),
      trailing: IconButton(
        icon: const Icon(Icons.phone_outlined),
        iconSize: 22,
        color: theme.colorScheme.primary,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        onPressed: () async {
          // PHASE-2: Replace with NativeCallService.makeCall() after telecom integration is verified
          await FlutterPhoneDirectCaller.callNumber(log.phoneNumber);
        },
      ),
    );
  }
}

// ── Avatar with colour-coded call-type badge ──────────────────────────────────

class _AvatarWithBadge extends StatelessWidget {
  final String name;
  final CallType callType;
  final Color backgroundColor; // used for the badge border ring

  const _AvatarWithBadge({
    required this.name,
    required this.callType,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AvatarWidget(name: name, size: 48),
        Positioned(
          bottom: -2,
          right: -2,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: _callColor(callType),
              shape: BoxShape.circle,
              border: Border.all(color: backgroundColor, width: 1.5),
            ),
            child: Icon(_callIcon(callType), color: Colors.white, size: 10),
          ),
        ),
      ],
    );
  }
}

// ── Subtitle row (time · duration · SIM) ─────────────────────────────────────

class _Subtitle extends StatelessWidget {
  final CallLogModel log;
  final ThemeData theme;

  const _Subtitle({required this.log, required this.theme});

  @override
  Widget build(BuildContext context) {
    final timeStr = _formatTime(log.timestamp);
    final durStr = _formatDuration(log.callType, log.duration);
    final simStr =
        log.simSlot != null ? ' · SIM${log.simSlot}' : '';

    final text = [timeStr, if (durStr != null) durStr].join(' · ') + simStr;

    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: theme.textTheme.bodyMedium?.color,
      ),
    );
  }
}

// ── Static helper functions ───────────────────────────────────────────────────

Color _callColor(CallType type) {
  switch (type) {
    case CallType.missed:
      return AppColors.missedCallRed;
    case CallType.incoming:
      return AppColors.incomingCall;
    case CallType.outgoing:
      return AppColors.outgoingCall;
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
  }
}

/// Formats a timestamp as "صبح ۰۸:۳۰", "بعدازظهر ۱۴:۱۵", etc.
String _formatTime(DateTime dt) {
  final ph = PersianUtils.toPersianNumber(dt.hour.toString().padLeft(2, '0'));
  final pm = PersianUtils.toPersianNumber(dt.minute.toString().padLeft(2, '0'));
  return '${_timePeriod(dt.hour)} $ph:$pm';
}

String _timePeriod(int hour) {
  if (hour < 12) return 'صبح';
  if (hour == 12) return 'ظهر';
  if (hour < 18) return 'بعدازظهر';
  return 'شب';
}

/// Returns a human-readable duration string, or null if unavailable (missed/rejected).
String? _formatDuration(CallType type, int? seconds) {
  if (type == CallType.missed) return 'رد شد';
  if (seconds == null || seconds == 0) return null;
  final m = seconds ~/ 60;
  final s = seconds % 60;
  if (m == 0) {
    return '${PersianUtils.toPersianNumber(s.toString())} ث';
  }
  final ps = PersianUtils.toPersianNumber(s.toString().padLeft(2, '0'));
  final pm = PersianUtils.toPersianNumber(m.toString());
  return '$pm:$ps';
}
