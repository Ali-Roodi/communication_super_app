import 'package:equatable/equatable.dart';
import 'package:communication_super_app/core/utils/calendar_type.dart';
import 'package:communication_super_app/core/utils/message_text_scale.dart';
import 'package:communication_super_app/features/dialer/services/auto_redial_policy.dart';

export 'package:communication_super_app/core/utils/calendar_type.dart';

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
  final bool autoRedial;

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
    this.autoRedial = false,
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
      case BoolSetting.autoRedial:
        return autoRedial;
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
    bool? autoRedial,
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
      autoRedial: autoRedial ?? this.autoRedial,
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
      case BoolSetting.autoRedial:
        return copyWith(autoRedial: value);
    }
  }

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
    autoRedial,
    autoRedialAttempts,
    calendarType,
    messageTextScale,
  ];
}
