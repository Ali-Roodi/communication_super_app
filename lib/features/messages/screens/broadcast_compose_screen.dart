import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';

import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';

/// One recipient of a group send.
class BroadcastRecipient {
  const BroadcastRecipient({required this.phoneNumber, this.name});

  final String phoneNumber;
  final String? name;

  /// The key a recipient is deduplicated by — the same canonical thread id the
  /// rest of the app uses, so «+98912…» and «0912…» are one person.
  String get key => PhoneNormalizer.toThreadId(phoneNumber);

  String get label =>
      name ??
      PersianUtils.displayPhone(PhoneNormalizer.toNational(phoneNumber));
}

/// «پیام گروهی» — one message, several recipients.
///
/// **It sends one SMS per recipient, and says so.** This app deliberately does
/// not do MMS (see the SMS pipeline notes), and a group *conversation* is an
/// MMS construct: without it there is no thread the replies could come back
/// into. Google Messages behaves exactly this way with «Group MMS» switched
/// off — the message goes out individually and each answer lands in that
/// person's own chat — so this is the honest version of the feature rather
/// than a group thread that could never receive anything.
class BroadcastComposeScreen extends StatefulWidget {
  const BroadcastComposeScreen({
    super.key,
    required this.recipients,
    this.initialText,
    this.title = 'پیام گروهی',
  });

  final List<BroadcastRecipient> recipients;
  final String? initialText;
  final String title;

  @override
  State<BroadcastComposeScreen> createState() => _BroadcastComposeScreenState();
}

class _BroadcastComposeScreenState extends State<BroadcastComposeScreen> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText ?? '',
  );

  /// Recipients still selected — each chip can be removed here, which is the
  /// last chance to drop someone before the message actually goes out.
  late final List<BroadcastRecipient> _recipients = [...widget.recipients];

  SimCard? _sim;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _sim = SimService.defaultFor(SimUse.sms);
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSend =>
      !_sending && _recipients.isNotEmpty && _controller.text.trim().isNotEmpty;

  Future<void> _pickSim() async {
    final chosen = await showSimPicker(
      context,
      title: 'ارسال با کدام سیم‌کارت؟',
      subtitle: widget.title,
      selected: _sim,
    );
    if (chosen == null || !mounted) return;
    setState(() => _sim = chosen);
  }

  void _send() {
    final body = _controller.text.trim();
    if (body.isEmpty || _recipients.isEmpty) return;
    setState(() => _sending = true);

    final bloc = context.read<MessageBloc>();
    for (final recipient in _recipients) {
      bloc.add(
        SendMessage(
          phoneNumber: recipient.phoneNumber,
          body: body,
          subscriptionId: _sim?.subscriptionId,
        ),
      );
    }
    // Every send lands in its own conversation, so there is no thread to stay
    // on: report and go back to the inbox.
    //
    // The messenger is resolved BEFORE the pop — afterwards this screen's
    // element is on its way out and looking an inherited widget up through it
    // is a race with the route's own teardown.
    final count = PersianUtils.toPersianNumber('${_recipients.length}');
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop(true);
    messenger.showSnackBar(
      SnackBar(content: Text('پیام برای $count مخاطب ارسال شد')),
    );
  }

  /// GSM-7 fits 160 characters in one SMS (153 per part once split); Persian is
  /// Unicode and fits 70 (67 per part). Same rule as the chat composer — a
  /// group send is where it matters most, since every part is billed once **per
  /// recipient**.
  static bool _isUnicode(String s) => s.runes.any((r) => r > 0x7F);

  ({int segments, int remaining}) _segmentsOf(String text) {
    final len = text.length;
    final unicode = _isUnicode(text);
    final single = unicode ? 70 : 160;
    final multi = unicode ? 67 : 153;
    final segments = len == 0 ? 0 : (len <= single ? 1 : (len / multi).ceil());
    final remaining = (segments <= 1 ? single - len : segments * multi - len)
        .clamp(0, single);
    return (segments: segments, remaining: remaining);
  }

  /// «۲۰ کاراکتر مانده · ۲ پیامک × ۳ گیرنده = ۶ پیامک».
  ///
  /// Shown only once it says something — the message is about to split, or it
  /// already has. A group send is billed per part **per recipient**, so the
  /// multiplication is the number that actually matters and the chat composer's
  /// per-message counter would understate it.
  Widget _buildCounter(ThemeData theme) {
    final text = _controller.text;
    final counts = _segmentsOf(text);
    final segments = counts.segments;
    if (text.isEmpty || (segments <= 1 && counts.remaining > 20)) {
      return const SizedBox(height: 12);
    }
    final total = segments * _recipients.length;
    final parts = PersianUtils.toPersianNumber('$segments');
    final people = PersianUtils.toPersianNumber('${_recipients.length}');
    final all = PersianUtils.toPersianNumber('$total');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        _recipients.length > 1
            ? '${PersianUtils.toPersianNumber('${counts.remaining}')} کاراکتر مانده · $parts پیامک × $people گیرنده = $all پیامک'
            : '${PersianUtils.toPersianNumber('${counts.remaining}')} کاراکتر مانده · $parts پیامک',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: RtlAppBar(
          title: widget.title,
          actions: [
            if (SimService.isMultiSim)
              IconButton(
                icon: const Icon(Icons.sim_card_outlined),
                tooltip: _sim == null ? 'سیم‌کارت' : _sim!.slotLabel,
                onPressed: _pickSim,
              ),
          ],
        ),
        body: Column(
          children: [
            // Recipients
            Container(
              width: double.infinity,
              color: scheme.surfaceContainerLow,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'گیرندگان (${PersianUtils.toPersianNumber('${_recipients.length}')})',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    children: [
                      for (final recipient in _recipients)
                        InputChip(
                          label: Text(recipient.label),
                          onDeleted: _sending
                              ? null
                              : () => setState(
                                  () => _recipients.remove(recipient),
                                ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            // Said out loud: without MMS this is a mass text, not a group chat,
            // and the difference decides where the replies turn up.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'پیام به‌صورت جداگانه برای هر مخاطب ارسال می‌شود و پاسخ‌ها در گفتگوی خودشان می‌آید.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: 'متن پیام',
                    filled: true,
                    fillColor: scheme.raisedSurface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.all(16),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildCounter(theme),
                    FilledButton.icon(
                      onPressed: _canSend ? _send : null,
                      icon: const Icon(Icons.send),
                      label: Text(
                        _recipients.isEmpty
                            ? 'ارسال'
                            : 'ارسال به ${PersianUtils.toPersianNumber('${_recipients.length}')} مخاطب',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
