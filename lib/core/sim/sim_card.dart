import 'dart:ui' show Color;

import 'package:equatable/equatable.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';

/// One active SIM, as reported by `SimRegistry` on the Android side.
///
/// The identity that travels through the app is [subscriptionId] — it is what
/// telephony, the SMS provider and the call log all record. [slotIndex] is only
/// ever used for *display*: a subscription id is an opaque per-device counter
/// that changes when a card is re-inserted, so a stored "SIM 2" must not mean
/// "subscription 7" and a shown "سیم ۲" must not mean "subscription id 2".
class SimCard extends Equatable {
  const SimCard({
    required this.subscriptionId,
    required this.slotIndex,
    required this.displayName,
    required this.carrierName,
    required this.number,
    this.color,
    this.isEmbedded = false,
  });

  /// Sentinel for "no particular SIM" — mirrors
  /// `SimRegistry.INVALID_SUBSCRIPTION_ID` and `SubscriptionManager`'s own.
  static const int invalidSubscriptionId = -1;

  final int subscriptionId;
  final int slotIndex;
  final String displayName;
  final String carrierName;

  /// The SIM's own number. Usually blank — most carriers never write it to the
  /// card — so nothing may depend on it being present.
  final String number;

  /// The tint the user picked for this SIM in Android settings, as an ARGB int.
  final int? color;

  final bool isEmbedded;

  factory SimCard.fromMap(Map<String, dynamic> map) {
    return SimCard(
      subscriptionId:
          (map['subscriptionId'] as num?)?.toInt() ?? invalidSubscriptionId,
      slotIndex: (map['slotIndex'] as num?)?.toInt() ?? 0,
      displayName: map['displayName'] as String? ?? '',
      carrierName: map['carrierName'] as String? ?? '',
      number: map['number'] as String? ?? '',
      color: (map['color'] as num?)?.toInt(),
      isEmbedded: map['isEmbedded'] as bool? ?? false,
    );
  }

  /// «سیم ۱» / «سیم ۲» — the slot, in Persian digits, 1-based like the tray.
  String get slotLabel =>
      'سیم ${PersianUtils.toPersianNumber('${slotIndex + 1}')}';

  /// What the user named this SIM, falling back to the carrier and finally to
  /// the slot, so this is never empty.
  String get name {
    if (displayName.trim().isNotEmpty) return displayName.trim();
    if (carrierName.trim().isNotEmpty) return carrierName.trim();
    return slotLabel;
  }

  /// Second line of a SIM row: the card's own number when the carrier wrote
  /// one, otherwise the carrier name — and nothing at all when [name] already
  /// *is* the carrier name, which is the common case.
  String? get subtitle {
    if (number.trim().isNotEmpty) return PersianUtils.displayPhone(number);
    final carrier = carrierName.trim();
    if (carrier.isEmpty || carrier == name) return null;
    return carrier;
  }

  Color? get tint {
    final value = color;
    // A fully transparent tint is how some OEMs say "unset" — treating it as a
    // colour paints an invisible chip.
    if (value == null || (value >> 24) & 0xFF == 0) return null;
    return Color(value);
  }

  @override
  List<Object?> get props => [
    subscriptionId,
    slotIndex,
    displayName,
    carrierName,
    number,
    color,
    isEmbedded,
  ];
}

/// The system-wide "use this SIM unless told otherwise" settings.
///
/// Google Messages and Google Phone both read these: when the user has pinned a
/// default there is **no picker**, the send/dial simply uses it. The picker
/// only appears while the default is «هر بار بپرس»
/// ([SimCard.invalidSubscriptionId]).
class SimDefaults extends Equatable {
  const SimDefaults({required this.sms, required this.voice, required this.data});

  const SimDefaults.unknown()
    : sms = SimCard.invalidSubscriptionId,
      voice = SimCard.invalidSubscriptionId,
      data = SimCard.invalidSubscriptionId;

  final int sms;
  final int voice;
  final int data;

  factory SimDefaults.fromMap(Map<String, dynamic> map) => SimDefaults(
    sms: (map['sms'] as num?)?.toInt() ?? SimCard.invalidSubscriptionId,
    voice: (map['voice'] as num?)?.toInt() ?? SimCard.invalidSubscriptionId,
    data: (map['data'] as num?)?.toInt() ?? SimCard.invalidSubscriptionId,
  );

  @override
  List<Object?> get props => [sms, voice, data];
}
