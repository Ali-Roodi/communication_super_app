import 'package:flutter/material.dart';

import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';

import '../sim_card.dart';
import '../sim_service.dart';

/// The SIM affordances, in one place so the composer, the dialer, the call log
/// and the message details cannot drift apart.
///
/// The rule every one of them follows — taken from Google Messages and Google
/// Phone — is: **nothing SIM-related is drawn on a single-SIM phone.** Not a
/// greyed chip, not a "SIM 1" badge. Two SIMs is what turns the whole surface
/// on, which is why every entry point here early-returns on
/// [SimService.isMultiSim].

/// Small colour-coded SIM marker: the slot number in a tinted rounded square.
///
/// Sized to sit inline with caption text (a bubble's timestamp row, a call-log
/// row), because that is where the information belongs — a SIM badge that
/// needs its own line is a badge nobody reads.
class SimBadge extends StatelessWidget {
  const SimBadge({super.key, required this.sim, this.compact = true});

  final SimCard sim;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = sim.tint ?? _fallbackTint(scheme, sim.slotIndex);
    final label = PersianUtils.toPersianNumber('${sim.slotIndex + 1}');

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 8,
        vertical: compact ? 1 : 3,
      ),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppDimensions.radiusSm - 2),
      ),
      child: Text(
        compact ? label : '${sim.slotLabel} · ${sim.name}',
        style:
            (compact
                    ? Theme.of(context).textTheme.labelSmall
                    : Theme.of(context).textTheme.labelMedium)
                ?.copyWith(
                  color: tint,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
      ),
    );
  }
}

/// Distinct per-slot colours for a card whose tint Android never set. Reads as
/// the same "SIM 1 is blue, SIM 2 is orange" convention every OEM ships.
Color _fallbackTint(ColorScheme scheme, int slotIndex) =>
    slotIndex == 0 ? scheme.primary : scheme.tertiary;

/// A tappable SIM chip — the composer's «سیم ۱» pill and the dialer's SIM
/// button. Renders nothing at all when the phone has one SIM.
class SimChip extends StatelessWidget {
  const SimChip({
    super.key,
    required this.sim,
    required this.onTap,
    this.dense = false,
  });

  /// Null = the user has not chosen and there is no default: the chip invites
  /// the choice rather than lying about which card will be used.
  final SimCard? sim;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (!SimService.isMultiSim) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final selected = sim;
    // Muted on purpose. The chip sits inside the composer pill next to the
    // hint text, and at full saturation the carrier's own SIM colour (a loud
    // green on this device) read as the loudest thing in an empty composer —
    // louder than the send button. Blending it toward the surface keeps the
    // per-SIM identity while letting the message the user is writing lead.
    final tint = selected == null
        ? scheme.onSurfaceVariant
        : Color.lerp(
            selected.tint ?? _fallbackTint(scheme, selected.slotIndex),
            scheme.onSurfaceVariant,
            0.55,
          )!;

    // A tonal pill, not bare text: it is a control, and inside the composer
    // pill a label with no ground of its own reads as part of the hint.
    return Semantics(
      button: true,
      label: selected == null
          ? 'انتخاب سیم‌کارت'
          : 'ارسال با ${selected.slotLabel}، ${selected.name}',
      child: Material(
        color: tint.withValues(alpha: 0.10),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 7 : 9,
              vertical: dense ? 3 : 5,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.sim_card_outlined,
                  size: dense ? 13 : AppDimensions.iconSm,
                  color: tint,
                ),
                const SizedBox(width: 3),
                Text(
                  selected?.slotLabel ?? 'سیم‌کارت',
                  style:
                      (dense
                              ? Theme.of(context).textTheme.labelSmall
                              : Theme.of(context).textTheme.labelMedium)
                          ?.copyWith(
                            color: tint,
                            fontWeight: FontWeight.w600,
                            height: 1.1,
                          ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks which SIM to use. Returns null when dismissed.
///
/// [title] names the action rather than the setting («ارسال با کدام
/// سیم‌کارت؟» / «تماس با کدام سیم‌کارت؟»), matching both Google apps: the
/// sheet is part of sending, not a settings page.
Future<SimCard?> showSimPicker(
  BuildContext context, {
  required String title,
  SimCard? selected,
  String? subtitle,
}) async {
  final sims = SimService.cached;
  if (sims.length < 2) return sims.isEmpty ? null : sims.first;

  return showModalBottomSheet<SimCard>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.raisedSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppDimensions.radiusXl),
      ),
    ),
    builder: (sheetContext) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: AppDimensions.paddingMd),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimensions.paddingLg,
              ),
              child: Text(
                title,
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppDimensions.paddingXs),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimensions.paddingLg,
                ),
                child: Text(
                  subtitle,
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppDimensions.paddingSm),
            for (final sim in sims)
              _SimRow(
                sim: sim,
                selected: sim.subscriptionId == selected?.subscriptionId,
                onTap: () => Navigator.of(sheetContext).pop(sim),
              ),
            const SizedBox(height: AppDimensions.paddingSm),
          ],
        ),
      ),
    ),
  );
}

class _SimRow extends StatelessWidget {
  const _SimRow({
    required this.sim,
    required this.selected,
    required this.onTap,
  });

  final SimCard sim;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = sim.tint ?? _fallbackTint(scheme, sim.slotIndex);
    final subtitle = sim.subtitle;

    return ListTile(
      onTap: onTap,
      leading: Container(
        width: AppDimensions.avatarSm,
        height: AppDimensions.avatarSm,
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.sim_card, color: tint, size: AppDimensions.iconLg),
      ),
      title: Text('${sim.slotLabel} · ${sim.name}'),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: selected
          ? Icon(Icons.check_circle, color: scheme.primary)
          : null,
    );
  }
}

/// Rebuilds [builder] whenever the SIM roster or the system's pinned defaults
/// change.
///
/// Every SIM affordance in the app reads [SimService.cached] / `isMultiSim`
/// **statically**, inside `build` — a bubble's badge or a call-log row cannot
/// await a platform channel to find out which card carried it. That is the
/// right call for the read, and it is also why nothing on screen noticed a
/// second card going into the phone: no widget depended on the roster, so the
/// app stayed single-SIM-shaped until it was killed and reopened.
///
/// So the screens that keep a SIM surface *visible* wrap it in this. It is a
/// plain [ValueListenableBuilder] over [SimService.revision]; the roster itself
/// is still read statically inside [builder], so no call site changes shape.
/// Screens that only read the roster at gesture time (a long-press picker, an
/// action sheet) need nothing — by then the static cache is already current.
class SimAware extends StatelessWidget {
  const SimAware({super.key, required this.builder, this.child});

  final ValueWidgetBuilder<int> builder;

  /// Passed through untouched to [builder] — the subtree that does *not*
  /// depend on the roster and so must not be rebuilt with it.
  final Widget? child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: SimService.revision,
    builder: builder,
    child: child,
  );
}
