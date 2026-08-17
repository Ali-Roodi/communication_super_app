import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';

import 'call_ui_coordinator.dart';

/// The green «بازگشت به تماس» strip across the top of the app while a call is
/// running with its screen put away.
///
/// It is mounted from `MaterialApp.builder`, i.e. **above the navigator**, and
/// that placement is the whole point: the reason to leave the call screen is to
/// use the app — look a number up, read a message — and every one of those is a
/// pushed route. A bar inside `MainNavigation` would vanish under the first
/// conversation the user opened, which is exactly where they need it.
///
/// It is the in-app half of the pair. The other half is the shade's «تماس در
/// جریان» card (`CallInCallService.refreshOngoingNotification`), which covers
/// leaving the app altogether and, from Android 12, puts the green chip in the
/// status bar.
class ReturnToCallBar extends StatelessWidget {
  /// The whole app, drawn under the bar.
  final Widget child;

  /// Height of the bar's own content, above the status-bar inset it also
  /// covers. Fixed, because the same number is added to the app's top padding
  /// so nothing ends up underneath it.
  static const double _kBarHeight = 32;

  const ReturnToCallBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: CallUiCoordinator.minimized,
      // `child` is passed through the builder rather than rebuilt inside it:
      // the app's whole widget tree — the Navigator and every route in it —
      // hangs off this, and rebuilding (or re-parenting) it would tear the
      // route stack down. The tree SHAPE is constant for the same reason: the
      // Stack and the MediaQuery are always there, only the bar comes and goes.
      child: child,
      builder: (context, minimized, app) => Stack(
        children: [
          MediaQuery(
            // The bar covers the top of the screen, so the app is told the
            // screen starts lower down — that is what keeps a conversation's
            // header (and every SafeArea) out from under it, without moving the
            // app in the tree.
            data: minimized
                ? media.copyWith(
                    padding: media.padding.copyWith(
                      top: media.padding.top + _kBarHeight,
                    ),
                  )
                : media,
            child: app!,
          ),
          if (minimized)
            const Positioned(top: 0, left: 0, right: 0, child: _Bar()),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar();

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Material(
        color: AppColors.callAnswerGreen,
        child: InkWell(
          onTap: CallUiCoordinator.restore,
          child: Container(
            height: topInset + ReturnToCallBar._kBarHeight,
            alignment: Alignment.bottomCenter,
            padding: EdgeInsets.fromLTRB(16, topInset, 16, 7),
            child: BlocBuilder<DialerBloc, DialerState>(
              buildWhen: (a, b) =>
                  a.callStatus != b.callStatus ||
                  a.activePhone != b.activePhone ||
                  a.activeName != b.activeName ||
                  a.callConnectedAt != b.callConnectedAt ||
                  a.isConference != b.isConference,
              builder: (context, state) {
                final who = state.isConference
                    ? 'تماس گروهی'
                    : (state.activeName ??
                          PersianUtils.displayPhone(state.activePhone));
                return Row(
                  children: [
                    const Icon(
                      Icons.phone_in_talk,
                      size: 18,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        who.isEmpty ? 'تماس در جریان' : who,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Ticks off the same moment telecom reports, so the bar and
                    // the call screen can never disagree by a second.
                    _CallTimerText(
                      connectedAt: state.callConnectedAt,
                      onHold: state.callStatus == CallStatus.onHold,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// mm:ss since [connectedAt], repainted once a second.
///
/// Derived from an absolute moment rather than an incremented counter: it is
/// drawn in two places that mount and unmount independently (this bar and the
/// call screen), and a counter would restart at zero in each of them.
class _CallTimerText extends StatefulWidget {
  final DateTime? connectedAt;
  final bool onHold;

  const _CallTimerText({required this.connectedAt, required this.onHold});

  @override
  State<_CallTimerText> createState() => _CallTimerTextState();
}

class _CallTimerTextState extends State<_CallTimerText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      widget.onHold ? 'در انتظار' : formatCallDuration(widget.connectedAt),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// «۰۲:۱۷» — talk time since [connectedAt], in Persian digits.
///
/// Null (still dialing, or a call the roster never reported a connect time
/// for) reads «…»: the call exists, it just has no duration yet, and printing
/// «۰۰:۰۰» there claims a connected call that isn't.
String formatCallDuration(DateTime? connectedAt) {
  if (connectedAt == null) return '…';
  var seconds = DateTime.now().difference(connectedAt).inSeconds;
  // A clock adjustment mid-call must not print a negative duration.
  if (seconds < 0) seconds = 0;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return PersianUtils.toPersianNumber(h > 0 ? '$h:$mm:$ss' : '$mm:$ss');
}
