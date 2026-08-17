import 'package:equatable/equatable.dart';
import 'package:communication_super_app/core/utils/calendar_type.dart';
import 'package:communication_super_app/core/utils/message_text_scale.dart';

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
    calendarType,
    messageTextScale,
  ];
}
