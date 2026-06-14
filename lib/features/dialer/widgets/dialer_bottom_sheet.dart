import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/screens/dialer_screen.dart';

/// Opens the dialer keypad as a draggable modal bottom sheet (Section 1 spec) —
/// the dialer is launched from the FAB, snaps between 60% and 90% of the screen
/// height, and can be dragged down to dismiss.
///
/// The globally-provided [DialerBloc] is forwarded via [BlocProvider.value] so
/// the sheet shares the same call/keypad state as the rest of the app.
Future<void> showDialerBottomSheet(BuildContext context) {
  final dialerBloc = context.read<DialerBloc>();
  // Start every session from a clean keypad.
  dialerBloc.add(const DialerNumberCleared());

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => BlocProvider.value(
      value: dialerBloc,
      child: const _DialerSheet(),
    ),
  );
}

class _DialerSheet extends StatelessWidget {
  const _DialerSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.of(context).size.height * 0.9;

    // Fixed-height sheet (drag-to-dismiss via the modal's default handler). The
    // dialer content is bottom-aligned inside it — DialerScreen's own layout
    // puts the suggestions/empty space on top and the number + keypad + actions
    // at the bottom of the sheet.
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: theme.dividerColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Expanded(child: DialerScreen()),
        ],
      ),
    );
  }
}
