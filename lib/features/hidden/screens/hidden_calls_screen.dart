import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure/services/hidden_bridge.dart';
import 'package:communication_super_app/features/secure/widgets/secure_locked_view.dart';

import '../bloc/hidden_bloc.dart';
import '../repositories/hidden_contacts_repository.dart';

/// «تماس‌های مخفی»: calls with hidden-phonebook numbers, moved out of the
/// system call log (matrix row 11). Reached from the row at the top of
/// «اخیر» and from a hidden contact's «تماس بی‌پاسخ».
class HiddenCallsScreen extends StatefulWidget {
  const HiddenCallsScreen({super.key});

  @override
  State<HiddenCallsScreen> createState() => _HiddenCallsScreenState();
}

class _HiddenCallsScreenState extends State<HiddenCallsScreen> {
  @override
  void initState() {
    super.initState();
    // A call that just ended may still be on its way out of the call log.
    context.read<HiddenBloc>().add(const HiddenRefresh());
    const HiddenBridge().clearMissedNotice();
  }

  Future<void> _confirmClear() async {
    final bloc = context.read<HiddenBloc>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('پاک کردن تماس‌های مخفی؟'),
          content: const Text('همه سوابق تماس مخفی از بخش امن پاک می‌شود.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('پاک کردن'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) bloc.add(const HiddenClearCalls());
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocBuilder<HiddenBloc, HiddenState>(
        builder: (context, state) {
          final ready = state.status == HiddenStatus.ready;
          return Scaffold(
            appBar: RtlAppBar(
              title: 'تماس‌های مخفی',
              actions: [
                if (ready && state.calls.isNotEmpty)
                  IconButton(
                    tooltip: 'پاک کردن همه',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: _confirmClear,
                  ),
              ],
            ),
            body: switch (state.status) {
              HiddenStatus.locked => const SecureLockedView(
                message:
                    'تماس‌های مخفی داخل بخش امن نگهداری می‌شوند. برای دیدن '
                    'آن‌ها، بخش امن را باز کنید.',
              ),
              HiddenStatus.loading => const SizedBox.shrink(),
              HiddenStatus.ready =>
                state.calls.isEmpty
                    ? const _Empty()
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 32),
                        itemCount: state.calls.length,
                        itemBuilder: (context, i) => HiddenCallTile(
                          call: state.calls[i],
                          name: state.names[state.calls[i].phone],
                        ),
                      ),
            },
          );
        },
      ),
    );
  }
}

/// One hidden call: what it was, with whom, when. Tap calls back; long-press
/// deletes it.
class HiddenCallTile extends StatelessWidget {
  const HiddenCallTile({super.key, required this.call, this.name});

  final HiddenCall call;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label, color) = switch (call.callType) {
      1 => (Icons.call_received, 'ورودی', scheme.primary),
      2 => (Icons.call_made, 'خروجی', scheme.primary),
      3 => (Icons.call_missed, 'بی‌پاسخ', scheme.error),
      5 => (Icons.call_end, 'رد شده', scheme.error),
      6 => (Icons.block, 'مسدود', scheme.onSurfaceVariant),
      _ => (Icons.call, 'تماس', scheme.onSurfaceVariant),
    };
    final duration = call.duration ?? 0;
    final when = DateFormatter.formatDateAndTime(
      DateTime.fromMillisecondsSinceEpoch(call.timestamp),
    );
    final subtitle = [
      label,
      when,
      if (duration > 0) _duration(duration),
    ].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHighest,
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(
        name ?? PersianUtils.displayPhone(call.phone),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textDirection: name == null ? TextDirection.ltr : null,
        textAlign: TextAlign.right,
      ),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: 'تماس',
        icon: Icon(Icons.call_outlined, color: scheme.primary),
        onPressed: () => placeCall(context, call.phone),
      ),
      onLongPress: () => _confirmDelete(context),
    );
  }

  static String _duration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return PersianUtils.toPersianNumber(
      m > 0 ? '$m:${s.toString().padLeft(2, '0')}' : '$s ثانیه',
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final bloc = context.read<HiddenBloc>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف این تماس؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) bloc.add(HiddenDeleteCalls([call.id]));
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.phone_locked_outlined,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            const Text('تماس مخفی‌ای نیست', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'تماس با شماره‌های دفترچه مخفی به‌جای سوابق گوشی اینجا ثبت '
              'می‌شود.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
