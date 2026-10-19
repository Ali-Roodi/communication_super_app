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
/// conversation header — and identically to the dials placed with no Flutter
/// engine (the missed-call «تماس»), because the native side decides by the
/// same rule (`SimRegistry.routeFor`):
///
/// 1. [sim] — a card picked for this one call (long-press, «تماس با سیم …»);
/// 2. the contact's own card («سیم‌کارت تماس» on the contact page);
/// 3. the app's default (Settings → «سیم‌کارت‌ها»);
/// 4. the phone's own default — dialled with **no** card named, so telecom
///    uses exactly the setting Android's settings show;
/// 5. otherwise ask.
///
/// One SIM: the question never exists. [suggested] is only the card the
/// picker opens on when it has to ask — «اخیر» passes the card a row's call
/// used, never as the choice (see `docs/architecture/dual-sim.md`).
///
/// Returns false when the user dismissed the picker, so a caller that also
/// closes a sheet can leave it open instead.
Future<bool> placeCall(
  BuildContext context,
  String number, {
  SimCard? sim,
  SimCard? suggested,
}) async {
  if (number.trim().isEmpty) return false;
  final choice = sim != null
      ? (go: true, subscriptionId: sim.subscriptionId)
      : await chooseVoiceSim(context, number, suggested: suggested);
  if (!choice.go) return false;
  await NativeCallService.instance.makeCall(
    number,
    subscriptionId: choice.subscriptionId,
  );
  return true;
}

/// The card an ordinary dial of [number] goes out on, asking only when the
/// rules in [placeCall] leave a real choice. [subscriptionId] null means "let
/// the native side route it" (the contact's card, the app's default or the
/// phone's); [go] false means the user backed out of the picker.
Future<({bool go, int? subscriptionId})> chooseVoiceSim(
  BuildContext context,
  String number, {
  SimCard? suggested,
}) async {
  final route = await SimService.instance.callRoute(number);
  if (!route.asks) return (go: true, subscriptionId: null);
  if (!context.mounted) return (go: false, subscriptionId: null);
  final picked = await showSimPicker(
    context,
    title: 'تماس با کدام سیم‌کارت؟',
    subtitle: number,
    selected: suggested,
  );
  return (go: picked != null, subscriptionId: picked?.subscriptionId);
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
  // Pre-selects what an ordinary tap would have used, so the sheet shows
  // which card is about to be overridden.
  final route = await SimService.instance.callRoute(number);
  if (!context.mounted) return false;
  final sim = await showSimPicker(
    context,
    title: title ?? 'تماس با کدام سیم‌کارت؟',
    subtitle: number,
    selected: route.sim,
  );
  if (sim == null || !context.mounted) return false;
  return placeCall(context, number, sim: sim);
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
