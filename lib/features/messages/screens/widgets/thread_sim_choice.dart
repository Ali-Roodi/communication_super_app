import 'package:flutter/material.dart';

import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import '../../repositories/thread_sim_repository.dart';

/// «ارسال با کدام سیم‌کارت؟» for one conversation — from its details page and
/// from the composer's SIM chip, so the two cannot drift apart.
///
/// Stored at once: a setting of the conversation, not of the next send.
/// «پیش‌فرض» hands it back to the default, which it then follows. Answers the
/// card the conversation now sends on and whether it is the conversation's
/// own (false = the default), or null when the sheet was dismissed.
Future<({SimCard? sim, bool own})?> chooseThreadSim(
  BuildContext context, {
  required String threadId,
  required String title,
  required SimCard? current,
}) async {
  final fallback = ThreadSimRepository.defaultSim;
  final chosen = await showSimChoice(
    context,
    title: 'ارسال با کدام سیم‌کارت؟',
    subtitle: title,
    defaultLabel: 'پیش‌فرض',
    defaultSubtitle: fallback == null
        ? null
        : '${fallback.slotLabel} · ${fallback.name} — طبق تنظیم «سیم‌کارت‌ها»',
    selected: current,
    defaultSelected: !ThreadSimRepository.hasChoice(threadId),
  );
  if (chosen == null) return null;
  await ThreadSimRepository().choose(threadId, chosen.sim);
  return (
    sim: chosen.sim ?? ThreadSimRepository.defaultSim,
    own: !chosen.isDefault,
  );
}
