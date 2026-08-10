import 'package:flutter/material.dart';

import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/contacts/widgets/contact_picker_sheet.dart';

import '../models/speed_dial_entry.dart';
import '../services/speed_dial_service.dart';

/// «شماره‌گیری سریع» — the eight assignable keypad digits and who each one
/// calls.
///
/// The keypad gesture (hold a digit) is the fast path; this screen is where the
/// assignments are *seen*. Without it, a key someone set months ago is a
/// mystery: nothing else in the app says that holding ۴ calls their mother.
class SpeedDialScreen extends StatefulWidget {
  const SpeedDialScreen({super.key});

  @override
  State<SpeedDialScreen> createState() => _SpeedDialScreenState();
}

class _SpeedDialScreenState extends State<SpeedDialScreen> {
  final _service = SpeedDialService.instance;

  @override
  void initState() {
    super.initState();
    _service.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'شماره‌گیری سریع'),
        body: ValueListenableBuilder<int>(
          valueListenable: _service.revision,
          builder: (context, _, child) {
            return ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                  child: Text(
                    'نگه‌داشتن هر کلید روی صفحه‌کلید شماره‌گیر، شمارهٔ همان کلید را می‌گیرد.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                // «۱» is listed but never assignable — it is voicemail, and a
                // row that quietly disappeared would read as a missing key.
                _voicemailRow(theme),
                for (final position in SpeedDialEntry.positions)
                  _row(theme, position),
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _voicemailRow(ThemeData theme) => ListTile(
    leading: _keyChip(theme, 1, muted: true),
    title: const Text('پست صوتی'),
    subtitle: Text('قابل تغییر نیست', style: theme.textTheme.bodySmall),
  );

  Widget _row(ThemeData theme, int position) {
    final entry = _service.cached(position);
    if (entry == null) {
      return ListTile(
        leading: _keyChip(theme, position, muted: true),
        title: Text(
          'تعیین نشده',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: const Icon(Icons.add),
        onTap: () => _assign(position),
      );
    }
    return ListTile(
      leading: _keyChip(theme, position),
      title: Text(entry.displayName),
      subtitle: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(PersianUtils.displayPhone(entry.phoneNumber)),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if ((entry.contactId ?? '').isNotEmpty)
            LazyContactAvatar(
              contactId: entry.contactId!,
              name: entry.displayName,
              size: 32,
            ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'حذف',
            color: AppColors.danger,
            onPressed: () => _service.clear(position),
          ),
        ],
      ),
      onTap: () => _assign(position),
      // The same override every call affordance in the app carries: a pinned
      // default SIM must never make the other card unreachable.
      onLongPress: SimService.isMultiSim
          ? () => placeCallPickingSim(context, entry.phoneNumber)
          : null,
    );
  }

  /// The digit itself, drawn as the key it is.
  Widget _keyChip(ThemeData theme, int position, {bool muted = false}) {
    final scheme = theme.colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? scheme.surfaceContainerHighest : scheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: Text(
        PersianUtils.toPersianNumber('$position'),
        style: TextStyle(
          fontSize: 18,
          color: muted ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
        ),
      ),
    );
  }

  Future<void> _assign(int position) async {
    final picked = await showContactPickerSheet(
      context,
      title: 'مخاطب کلید ${PersianUtils.toPersianNumber('$position')}',
    );
    if (picked == null) return;
    await _service.assign(
      position: position,
      phoneNumber: picked.number,
      name: picked.contact.name,
      contactId: picked.contact.id,
    );
  }
}
