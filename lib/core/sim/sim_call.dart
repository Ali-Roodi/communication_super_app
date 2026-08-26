import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:communication_super_app/features/dialer/services/native_call_service.dart';

import 'sim_card.dart';
import 'sim_service.dart';
import 'widgets/sim_picker.dart';

/// The one way the app places a call.
///
/// Every dial goes through here so the "which SIM" question is answered
/// identically everywhere — keypad, call log, contact page, favourites,
/// conversation header. Google Phone's rules, which this follows:
///
/// * one SIM → the question never exists;
/// * two SIMs and a default voice SIM pinned in Android settings → the tap
///   just calls, on the default (second-guessing the system setting is the
///   bug, not the feature);
/// * two SIMs and «هر بار بپرس» → ask on the dial;
/// * **and, always, an explicit way to override for this one call** —
///   [placeCallPickingSim], reached by long-pressing any call affordance and
///   by the «تماس با سیم …» rows. Without it a pinned default meant the other
///   card was simply unreachable from the app, which is the whole complaint
///   dual-SIM support exists to answer.
///
/// Returns false when the user dismissed the picker, so a caller that also
/// closes a sheet can leave it open instead.
Future<bool> placeCall(
  BuildContext context,
  String number, {
  SimCard? sim,
}) async {
  if (number.trim().isEmpty) return false;

  // An explicit choice is never re-asked.
  if (sim != null) {
    await NativeCallService.instance.makeCall(
      number,
      subscriptionId: sim.subscriptionId,
    );
    return true;
  }

  final resolved = await resolveVoiceSim(context, number);
  // A dismissed picker is a cancelled call — only on a phone that would have
  // asked can `null` mean that.
  if (resolved == null && _wouldAsk) return false;
  await NativeCallService.instance.makeCall(
    number,
    subscriptionId: resolved?.subscriptionId,
  );
  return true;
}

/// Always asks which SIM, then calls. The long-press gesture and the explicit
/// «تماس با سیم …» rows go through this.
///
/// On a single-SIM phone it is an ordinary call — there is nothing to ask.
Future<bool> placeCallPickingSim(
  BuildContext context,
  String number, {
  String? title,
}) async {
  if (number.trim().isEmpty) return false;
  if (!SimService.isMultiSim) return placeCall(context, number);

  await HapticFeedback.mediumImpact();
  if (!context.mounted) return false;
  final sim = await showSimPicker(
    context,
    title: title ?? 'تماس با کدام سیم‌کارت؟',
    subtitle: number,
    // Pre-selects what an ordinary tap would have used, so the sheet shows
    // which card is about to be overridden.
    selected: SimService.defaultFor(SimUse.voice),
  );
  if (sim == null || !context.mounted) return false;
  return placeCall(context, number, sim: sim);
}

/// Whether a plain dial would put a question in front of the user.
bool get _wouldAsk =>
    SimService.isMultiSim &&
    SimService.defaults.voice == SimCard.invalidSubscriptionId;

/// The SIM a call should go out on, asking only when there is a real choice.
///
/// Null means "let telecom decide" *or* "the user backed out" — [placeCall]
/// tells the two apart from the roster.
Future<SimCard?> resolveVoiceSim(BuildContext context, String number) async {
  if (!SimService.isMultiSim) return null;
  final pinned = SimService.defaultFor(SimUse.voice);
  if (pinned != null) return pinned;
  if (!context.mounted) return null;
  return showSimPicker(
    context,
    title: 'تماس با کدام سیم‌کارت؟',
    subtitle: number,
  );
}

/// The «تماس با سیم ۱» / «تماس با سیم ۲» rows a bottom sheet lists under its
/// ordinary «تماس» action. Empty on a single-SIM phone.
///
/// Google Phone puts exactly these in the call-log detail sheet; they are what
/// makes the second card reachable without changing a system setting.
/// [resolveNumber], when given, decides *which* number the call goes to at the
/// moment the row is tapped — a favourite is a person, and a person may have
/// several numbers. It runs after [onBeforeCall] (so the picker is not stacked
/// on the sheet it came from) and returning null cancels the call.
List<Widget> simCallRows(
  BuildContext context,
  String number, {
  VoidCallback? onBeforeCall,
  Future<String?> Function()? resolveNumber,
}) {
  if (!SimService.isMultiSim) return const <Widget>[];
  return [
    for (final sim in SimService.cached)
      ListTile(
        leading: const Icon(Icons.sim_card_outlined),
        title: Text('تماس با ${sim.slotLabel} · ${sim.name}'),
        onTap: () async {
          onBeforeCall?.call();
          final target = resolveNumber == null ? number : await resolveNumber();
          if (target == null || target.isEmpty || !context.mounted) return;
          await placeCall(context, target, sim: sim);
        },
      ),
  ];
}
