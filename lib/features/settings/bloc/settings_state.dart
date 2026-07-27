import 'package:equatable/equatable.dart';
import 'package:communication_super_app/core/utils/calendar_type.dart';

export 'package:communication_super_app/core/utils/calendar_type.dart';

enum TtyMode { off, full, hco, vco }

/// Which boolean setting an event targets (keeps the event surface small).
enum BoolSetting {
  showDialpadOnStart,
  sortByLastName,
  nameFormatLastFirst,
  alsoVibrate,
  keypadTones,
  dialpadTones,
  hearingAids,
  noiseReduction,
  callerIdSpam,
  filterSpam,

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
  final bool alsoVibrate;
  final bool keypadTones;
  final bool dialpadTones;
  final bool hearingAids;
  final bool noiseReduction;
  final bool callerIdSpam;
  final bool filterSpam;
  final bool linkPreviews;
  final bool swipeActions;
  final bool deliveryReports;
  final TtyMode ttyMode;
  final CalendarType calendarType;
  final List<String> quickReplies;

  const SettingsState({
    this.showDialpadOnStart = false,
    this.sortByLastName = false,
    this.nameFormatLastFirst = false,
    this.alsoVibrate = true,
    this.keypadTones = true,
    this.dialpadTones = true,
    this.hearingAids = false,
    this.noiseReduction = false,
    this.callerIdSpam = false,
    this.filterSpam = false,
    this.linkPreviews = true,
    this.swipeActions = true,
    this.deliveryReports = true,
    this.ttyMode = TtyMode.off,
    this.calendarType = CalendarType.jalali,
    this.quickReplies = defaultQuickReplies,
  });

  static const List<String> defaultQuickReplies = [
    'الان نمی‌توانم صحبت کنم',
    'بعداً تماس می‌گیرم',
    'در راه هستم',
    'لطفاً پیام بدهید',
  ];

  bool boolFor(BoolSetting key) {
    switch (key) {
      case BoolSetting.showDialpadOnStart:
        return showDialpadOnStart;
      case BoolSetting.sortByLastName:
        return sortByLastName;
      case BoolSetting.nameFormatLastFirst:
        return nameFormatLastFirst;
      case BoolSetting.alsoVibrate:
        return alsoVibrate;
      case BoolSetting.keypadTones:
        return keypadTones;
      case BoolSetting.dialpadTones:
        return dialpadTones;
      case BoolSetting.hearingAids:
        return hearingAids;
      case BoolSetting.noiseReduction:
        return noiseReduction;
      case BoolSetting.callerIdSpam:
        return callerIdSpam;
      case BoolSetting.filterSpam:
        return filterSpam;
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
    bool? alsoVibrate,
    bool? keypadTones,
    bool? dialpadTones,
    bool? hearingAids,
    bool? noiseReduction,
    bool? callerIdSpam,
    bool? filterSpam,
    bool? linkPreviews,
    bool? swipeActions,
    bool? deliveryReports,
    TtyMode? ttyMode,
    CalendarType? calendarType,
    List<String>? quickReplies,
  }) {
    return SettingsState(
      showDialpadOnStart: showDialpadOnStart ?? this.showDialpadOnStart,
      sortByLastName: sortByLastName ?? this.sortByLastName,
      nameFormatLastFirst: nameFormatLastFirst ?? this.nameFormatLastFirst,
      alsoVibrate: alsoVibrate ?? this.alsoVibrate,
      keypadTones: keypadTones ?? this.keypadTones,
      dialpadTones: dialpadTones ?? this.dialpadTones,
      hearingAids: hearingAids ?? this.hearingAids,
      noiseReduction: noiseReduction ?? this.noiseReduction,
      callerIdSpam: callerIdSpam ?? this.callerIdSpam,
      filterSpam: filterSpam ?? this.filterSpam,
      linkPreviews: linkPreviews ?? this.linkPreviews,
      swipeActions: swipeActions ?? this.swipeActions,
      deliveryReports: deliveryReports ?? this.deliveryReports,
      ttyMode: ttyMode ?? this.ttyMode,
      calendarType: calendarType ?? this.calendarType,
      quickReplies: quickReplies ?? this.quickReplies,
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
      case BoolSetting.alsoVibrate:
        return copyWith(alsoVibrate: value);
      case BoolSetting.keypadTones:
        return copyWith(keypadTones: value);
      case BoolSetting.dialpadTones:
        return copyWith(dialpadTones: value);
      case BoolSetting.hearingAids:
        return copyWith(hearingAids: value);
      case BoolSetting.noiseReduction:
        return copyWith(noiseReduction: value);
      case BoolSetting.callerIdSpam:
        return copyWith(callerIdSpam: value);
      case BoolSetting.filterSpam:
        return copyWith(filterSpam: value);
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
    alsoVibrate,
    keypadTones,
    dialpadTones,
    hearingAids,
    noiseReduction,
    callerIdSpam,
    filterSpam,
    linkPreviews,
    swipeActions,
    deliveryReports,
    ttyMode,
    calendarType,
    quickReplies,
  ];
}
