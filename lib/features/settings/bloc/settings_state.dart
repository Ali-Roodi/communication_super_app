import 'package:equatable/equatable.dart';

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
  final TtyMode ttyMode;
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
    this.ttyMode = TtyMode.off,
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
    TtyMode? ttyMode,
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
      ttyMode: ttyMode ?? this.ttyMode,
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
    ttyMode,
    quickReplies,
  ];
}
