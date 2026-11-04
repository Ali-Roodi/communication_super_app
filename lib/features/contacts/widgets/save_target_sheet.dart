import 'package:flutter/material.dart';

import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import '../models/contact_save_target.dart';

/// What a save target is called on screen.
String saveTargetLabel(ContactSaveTarget target) {
  if (target.isSim) {
    for (final sim in SimService.cached) {
      if (sim.subscriptionId == target.subscriptionId) {
        return '${sim.slotLabel} · ${sim.name}';
      }
    }
    return 'سیم‌کارت';
  }
  if (target.isAccount) return target.accountName!;
  return 'تلفن';
}

IconData saveTargetIcon(ContactSaveTarget target) {
  if (target.isSim) return Icons.sim_card_outlined;
  if (target.isAccount) return Icons.cloud_outlined;
  return Icons.smartphone_outlined;
}

String _hint(ContactSaveTarget target) {
  if (target.isSim) return 'فقط نام، شاید کوتاه‌شده، و یک شماره';
  if (target.isAccount) return 'خود گوشی با این حساب همگام می‌کند';
  return 'همهٔ فیلدها، عکس و چند شماره';
}

/// The «ذخیره در» sheet. Null when dismissed.
Future<ContactSaveTarget?> showSaveTargetSheet(
  BuildContext context, {
  required List<ContactSaveTarget> targets,
  ContactSaveTarget? selected,
}) {
  return showModalBottomSheet<ContactSaveTarget>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: AppDimensions.paddingSm),
              for (final target in targets)
                ListTile(
                  leading: Icon(saveTargetIcon(target)),
                  title: Text(saveTargetLabel(target)),
                  subtitle: Text(_hint(target)),
                  trailing: target == selected
                      ? const Icon(Icons.check_circle)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(target),
                ),
              const SizedBox(height: AppDimensions.paddingSm),
            ],
          ),
        ),
      ),
    ),
  );
}
