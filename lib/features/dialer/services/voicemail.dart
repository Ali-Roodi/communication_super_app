import 'package:flutter/material.dart';

import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';

import 'native_call_service.dart';

/// Dials the SIM's voicemail — the one place in the app that does.
///
/// Shared by the keypad's long-press on «۱» and the «پست صوتی» row in the
/// recents menu: this app holds the dialer role, so no stock dialer is left to
/// reach the mailbox from, and a gesture on one key is not an entry point
/// anyone finds.
///
/// On a dual-SIM phone the card is asked for **before** the number is read: the
/// two carriers have two different mailboxes, and a pinned default voice SIM
/// must not make the other card's mailbox unreachable (the rule the whole
/// dual-SIM layer follows — see `sim_call.dart`).
///
/// Returns true when a call was actually placed, so a caller sitting in a modal
/// sheet can dismiss it only then.
Future<bool> callVoicemail(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);

  SimCard? sim;
  if (SimService.isMultiSim) {
    sim = await showSimPicker(
      context,
      title: 'پست صوتی کدام سیم‌کارت؟',
      selected: SimService.defaultFor(SimUse.voice),
    );
    if (sim == null) return false; // dismissed = cancelled
  }

  final number = await NativeCallService.instance.getVoicemailNumber(
    subscriptionId: sim?.subscriptionId,
  );
  if (number == null || number.isEmpty) {
    // Common on Iranian SIMs: no mailbox was ever provisioned. Say so — dialing
    // a guessed short code reaches whatever the carrier put there instead.
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          sim == null
              ? 'شماره پست صوتی روی سیم‌کارت تنظیم نشده'
              : 'شماره پست صوتی روی ${sim.slotLabel} تنظیم نشده',
        ),
      ),
    );
    return false;
  }
  if (!context.mounted) return false;
  return placeCall(context, number, sim: sim);
}
