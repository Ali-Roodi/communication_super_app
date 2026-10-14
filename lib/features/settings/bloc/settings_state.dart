import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:communication_super_app/core/utils/calendar_type.dart';
import 'package:communication_super_app/core/utils/message_text_scale.dart';
import 'package:communication_super_app/features/dialer/services/auto_redial_policy.dart';
import 'package:communication_super_app/features/dialer/services/call_block_prefixes.dart';

export 'package:communication_super_app/core/utils/calendar_type.dart';
export 'package:communication_super_app/features/dialer/services/call_block_prefixes.dart';

/// Which boolean setting an event targets (keeps the event surface small).
///
/// Every entry here is read by something. A switch that only writes a
/// preference is not a setting, it is a lie about what the app does — the
/// TTY/hearing-aid/noise-reduction page, the caller-ID and spam-filter
/// switches and the «صدای صفحه‌کلید» / «لرزش هنگام تماس» pair were all exactly
/// that and were removed rather than left on screen.
enum BoolSetting {
  /// Pop the keypad sheet as soon as the app is opened.
  showDialpadOnStart,

  /// Order the address book by family name (`ContactNameStyle.sortByLastName`).
  sortByLastName,

  /// Render contacts as «نام خانوادگی، نام» (`ContactNameStyle.lastNameFirst`).
  nameFormatLastFirst,

  /// Play the DTMF tone when a keypad key is pressed.
  dialpadTones,

  /// Light haptic tick under every keypad key.
  dialpadHaptics,

  /// Render the link-preview card under a message that contains a URL.
  linkPreviews,

  /// Enable swipe-to-archive / swipe-to-toggle-read on inbox rows.
  swipeActions,

  /// Ask the carrier for an SMS delivery report (the ✓✓ tick).
  deliveryReports,

  /// Reject incoming calls that arrive with no caller id at all — a withheld
  /// («خصوصی») number, a payphone, or one telecom could not present.
  ///
  /// It has to be a rule rather than a list entry: there is no number to put in
  /// «هرزنامه و مسدودشده» for a caller who withheld theirs, which is why they
  /// were the one kind of nuisance call the app had no answer for. Off by
  /// default, like Google Phone's «Unknown» switch — a blocked caller is never
  /// told they were blocked, and a legitimate withheld call (a hospital, a
  /// bank) is not rare. Mirrored natively; see `CallPrefs`.
  blockUnknownCallers,

  /// «مسدود کردن تماس از شماره‌های خارج از مخاطبین» — reject a ringing call
  /// from a number that is not a saved (or hidden-phonebook) contact. Never a
  /// number the user called in the last week or a service number; see
  /// `CallRules`. Off by default. Mirrored natively together with the other
  /// rules ([SettingsState.callRulesChanged]).
  blockNonContacts,

  /// «مسدود کردن تماس‌های بین‌المللی» — reject a ringing call dialled from
  /// another country (`+`/`00` and not 98), unless it is a contact. Off by
  /// default.
  blockInternational,

  /// «مسدود کردن تماس‌های تبلیغاتی» — reject a ringing call whose number
  /// starts with one of [SettingsState.adPrefixes], unless it is a contact.
  /// There is no official marker for advertising calls; the list is what the
  /// user (and the default, `0942`) says. Off by default.
  blockAdvertising,

  /// «پنهان کردن محتوای اعلان‌ها» — while an app PIN is set, an SMS or
  /// missed-call notification shows neither who nor what. On by default: the
  /// point of a PIN is that the phone's lock screen does not read the inbox
  /// out. Only meaningful with a PIN; mirrored natively as `PIN && this`
  /// (`NotificationPrivacySync`).
  hideNotificationContent,

  /// «رمز برای پاسخ به تماس» — whether a ringing call waits behind the app
  /// lock. Off by default: the call screen goes *over* the lock and the lock
  /// is still there when the call ends, because a phone that has to be
  /// unlocked before it can be answered is unusable while driving. On, the
  /// incoming screen is covered by the lock whenever the app is locked, and
  /// «پاسخ» on the card opens it instead of answering (mirrored natively; see
  /// `CallPrefs`). Only a *ringing* call — one already answered (a headset, a
  /// car) is never put behind the PIN. Read by `AppLock`.
  pinToAnswerCalls,

  /// Dial a failed outgoing call again — busy, or dropped before it connected
  /// — after a visible countdown, up to [SettingsState.autoRedialAttempts]
  /// times. Off by default: a phone that dials by itself has to be asked for.
  /// Mirrored into `AutoRedialPolicy`, where `DialerBloc` reads it.
  autoRedial,
}

class SettingsState extends Equatable {
  final bool showDialpadOnStart;
  final bool sortByLastName;
  final bool nameFormatLastFirst;
  final bool dialpadTones;
  final bool dialpadHaptics;
  final bool linkPreviews;
  final bool swipeActions;
  final bool deliveryReports;
  final bool blockUnknownCallers;
  final bool pinToAnswerCalls;
  final bool autoRedial;
  final bool blockNonContacts;
  final bool blockInternational;
  final bool blockAdvertising;
  final bool hideNotificationContent;

  /// The prefixes [BoolSetting.blockAdvertising] refuses, in the national form
  /// (`0942`); see [CallBlockPrefixes].
  final List<String> adPrefixes;

  /// «تعداد تلاش‌ها» for [autoRedial] — one of
  /// [AutoRedialPolicy.attemptChoices].
  final int autoRedialAttempts;
  final CalendarType calendarType;

  /// «اندازه متن پیام» — multiplies the text size inside a conversation, on top
  /// of the phone's own font-size setting. 1.0 is normal; the pinch gesture on
  /// a thread writes here too, so the gesture and the settings row are one
  /// value and cannot disagree.
  final double messageTextScale;

  const SettingsState({
    this.showDialpadOnStart = false,
    this.sortByLastName = false,
    this.nameFormatLastFirst = false,
    this.dialpadTones = true,
    this.dialpadHaptics = true,
    this.linkPreviews = true,
    this.swipeActions = true,
    this.deliveryReports = true,
    this.blockUnknownCallers = false,
    this.pinToAnswerCalls = false,
    this.autoRedial = false,
    this.blockNonContacts = false,
    this.blockInternational = false,
    this.blockAdvertising = false,
    this.hideNotificationContent = true,
    this.adPrefixes = CallBlockPrefixes.defaults,
    this.autoRedialAttempts = AutoRedialPolicy.defaultAttempts,
    this.calendarType = CalendarType.jalali,
    this.messageTextScale = MessageTextScale.normal,
  });

  bool boolFor(BoolSetting key) {
    switch (key) {
      case BoolSetting.showDialpadOnStart:
        return showDialpadOnStart;
      case BoolSetting.sortByLastName:
        return sortByLastName;
      case BoolSetting.nameFormatLastFirst:
        return nameFormatLastFirst;
      case BoolSetting.dialpadTones:
        return dialpadTones;
      case BoolSetting.dialpadHaptics:
        return dialpadHaptics;
      case BoolSetting.linkPreviews:
        return linkPreviews;
      case BoolSetting.swipeActions:
        return swipeActions;
      case BoolSetting.deliveryReports:
        return deliveryReports;
      case BoolSetting.blockUnknownCallers:
        return blockUnknownCallers;
      case BoolSetting.pinToAnswerCalls:
        return pinToAnswerCalls;
      case BoolSetting.autoRedial:
        return autoRedial;
      case BoolSetting.blockNonContacts:
        return blockNonContacts;
      case BoolSetting.blockInternational:
        return blockInternational;
      case BoolSetting.blockAdvertising:
        return blockAdvertising;
      case BoolSetting.hideNotificationContent:
        return hideNotificationContent;
    }
  }

  SettingsState copyWith({
    bool? showDialpadOnStart,
    bool? sortByLastName,
    bool? nameFormatLastFirst,
    bool? dialpadTones,
    bool? dialpadHaptics,
    bool? linkPreviews,
    bool? swipeActions,
    bool? deliveryReports,
    bool? blockUnknownCallers,
    bool? pinToAnswerCalls,
    bool? autoRedial,
    bool? blockNonContacts,
    bool? blockInternational,
    bool? blockAdvertising,
    bool? hideNotificationContent,
    List<String>? adPrefixes,
    int? autoRedialAttempts,
    CalendarType? calendarType,
    double? messageTextScale,
  }) {
    return SettingsState(
      showDialpadOnStart: showDialpadOnStart ?? this.showDialpadOnStart,
      sortByLastName: sortByLastName ?? this.sortByLastName,
      nameFormatLastFirst: nameFormatLastFirst ?? this.nameFormatLastFirst,
      dialpadTones: dialpadTones ?? this.dialpadTones,
      dialpadHaptics: dialpadHaptics ?? this.dialpadHaptics,
      linkPreviews: linkPreviews ?? this.linkPreviews,
      swipeActions: swipeActions ?? this.swipeActions,
      deliveryReports: deliveryReports ?? this.deliveryReports,
      blockUnknownCallers: blockUnknownCallers ?? this.blockUnknownCallers,
      pinToAnswerCalls: pinToAnswerCalls ?? this.pinToAnswerCalls,
      autoRedial: autoRedial ?? this.autoRedial,
      blockNonContacts: blockNonContacts ?? this.blockNonContacts,
      blockInternational: blockInternational ?? this.blockInternational,
      blockAdvertising: blockAdvertising ?? this.blockAdvertising,
      hideNotificationContent:
          hideNotificationContent ?? this.hideNotificationContent,
      adPrefixes: adPrefixes ?? this.adPrefixes,
      autoRedialAttempts: autoRedialAttempts ?? this.autoRedialAttempts,
      calendarType: calendarType ?? this.calendarType,
      messageTextScale: messageTextScale ?? this.messageTextScale,
    );
  }

  SettingsState withBool(BoolSetting key, bool value) {
    switch (key) {
      case BoolSetting.showDialpadOnStart:
        return copyWith(showDialpadOnStart: value);
      case BoolSetting.sortByLastName:
        return copyWith(sortByLastName: value);
      case BoolSetting.nameFormatLastFirst:
        return copyWith(nameFormatLastFirst: value);
      case BoolSetting.dialpadTones:
        return copyWith(dialpadTones: value);
      case BoolSetting.dialpadHaptics:
        return copyWith(dialpadHaptics: value);
      case BoolSetting.linkPreviews:
        return copyWith(linkPreviews: value);
      case BoolSetting.swipeActions:
        return copyWith(swipeActions: value);
      case BoolSetting.deliveryReports:
        return copyWith(deliveryReports: value);
      case BoolSetting.blockUnknownCallers:
        return copyWith(blockUnknownCallers: value);
      case BoolSetting.pinToAnswerCalls:
        return copyWith(pinToAnswerCalls: value);
      case BoolSetting.autoRedial:
        return copyWith(autoRedial: value);
      case BoolSetting.blockNonContacts:
        return copyWith(blockNonContacts: value);
      case BoolSetting.blockInternational:
        return copyWith(blockInternational: value);
      case BoolSetting.blockAdvertising:
        return copyWith(blockAdvertising: value);
      case BoolSetting.hideNotificationContent:
        return copyWith(hideNotificationContent: value);
    }
  }

  /// Whether the rules mirrored into `CallPrefs` differ between this state and
  /// [other]. The four values travel to the native side as one set, so that a
  /// half-written mirror can never exist.
  bool callRulesChanged(SettingsState other) =>
      blockNonContacts != other.blockNonContacts ||
      blockInternational != other.blockInternational ||
      blockAdvertising != other.blockAdvertising ||
      !listEquals(adPrefixes, other.adPrefixes);

  @override
  List<Object?> get props => [
    showDialpadOnStart,
    sortByLastName,
    nameFormatLastFirst,
    dialpadTones,
    dialpadHaptics,
    linkPreviews,
    swipeActions,
    deliveryReports,
    blockUnknownCallers,
    pinToAnswerCalls,
    autoRedial,
    blockNonContacts,
    blockInternational,
    blockAdvertising,
    hideNotificationContent,
    adPrefixes,
    autoRedialAttempts,
    calendarType,
    messageTextScale,
  ];
}
