import 'package:flutter/services.dart';

/// Per-contact settings that live on [ContactsContract] columns rather than in
/// the Data rows `flutter_contacts` models — the custom ringtone, the
/// send-to-voicemail flag, the owning account, plus sharing / pinning the
/// contact and the third-party rows other apps wrote onto it.
///
/// Backed by `ContactExtrasHandler.kt`. Every call degrades to a null/empty
/// result rather than throwing, so a device that refuses one of them (an older
/// launcher with no pin support, a locked-down provider) just renders one fewer
/// row.
class ContactExtrasService {
  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/contact_extras',
  );

  static final ContactExtrasService instance = ContactExtrasService._();
  ContactExtrasService._();

  Future<ContactExtras?> getSettings(String contactId) async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'getSettings',
        {'contactId': contactId},
      );
      return map == null ? null : ContactExtras.fromMap(map);
    } on PlatformException {
      return null;
    }
  }

  Future<bool> setSendToVoicemail(String contactId, bool value) async {
    try {
      return await _channel.invokeMethod<bool>('setSendToVoicemail', {
            'contactId': contactId,
            'value': value,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the system ringtone picker. Resolves with the new ringtone once the
  /// user picks (already written to the contact), or null if they backed out.
  Future<({String? uri, String? title})?> pickRingtone(String contactId) async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'pickRingtone',
        {'contactId': contactId},
      );
      if (map == null) return null;
      return (
        uri: map['ringtoneUri'] as String?,
        title: map['ringtoneTitle'] as String?,
      );
    } on PlatformException {
      return null;
    }
  }

  Future<bool> clearRingtone(String contactId) async {
    try {
      return await _channel.invokeMethod<bool>('clearRingtone', {
            'contactId': contactId,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> shareContact(String contactId) async {
    try {
      return await _channel.invokeMethod<bool>('shareContact', {
            'contactId': contactId,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> pinToHome(String contactId) async {
    try {
      return await _channel.invokeMethod<bool>('pinToHome', {
            'contactId': contactId,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Runs one of a connected app's rows (its «تماس با …» / «پیام به …» action).
  /// False when no app on the phone can handle it.
  Future<bool> openConnectedAction(
    int dataId,
    String mimeType, {
    String? packageName,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('openConnectedAction', {
            'dataId': dataId,
            'mimeType': mimeType,
            'package': packageName,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<List<ConnectedApp>> getConnectedApps(String contactId) async {
    try {
      final list = await _channel.invokeListMethod<dynamic>(
        'getConnectedApps',
        {'contactId': contactId},
      );
      if (list == null) return const [];
      return [
        for (final e in list)
          ConnectedApp.fromMap(Map<String, dynamic>.from(e as Map)),
      ];
    } on PlatformException {
      return const [];
    }
  }
}

/// The contact's ringtone, voicemail routing and owning account.
class ContactExtras {
  /// Null means the contact uses the phone's default ringtone.
  final String? ringtoneUri;
  final String? ringtoneTitle;

  /// Title of the phone's own ringtone, so the row can read
  /// «پیش‌فرض (Galaxy Bells)» when no custom tone is set.
  final String? defaultRingtoneTitle;

  final bool sendToVoicemail;

  /// Display label of the account holding the contact («دستگاه», a Google
  /// address, …); null when the provider didn't report one.
  final String? accountLabel;
  final String? accountName;

  const ContactExtras({
    this.ringtoneUri,
    this.ringtoneTitle,
    this.defaultRingtoneTitle,
    this.sendToVoicemail = false,
    this.accountLabel,
    this.accountName,
  });

  factory ContactExtras.fromMap(Map<String, dynamic> map) => ContactExtras(
    ringtoneUri: map['ringtoneUri'] as String?,
    ringtoneTitle: map['ringtoneTitle'] as String?,
    defaultRingtoneTitle: map['defaultRingtoneTitle'] as String?,
    sendToVoicemail: map['sendToVoicemail'] as bool? ?? false,
    accountLabel: map['accountLabel'] as String?,
    accountName: map['accountName'] as String?,
  );

  /// What the ringtone row should read: the custom tone's name, or
  /// «پیش‌فرض (…)» naming the phone's own tone.
  String get ringtoneSummary {
    if (ringtoneTitle != null) return ringtoneTitle!;
    if (defaultRingtoneTitle != null) return 'پیش‌فرض ($defaultRingtoneTitle)';
    return 'پیش‌فرض';
  }

  ContactExtras copyWith({
    String? ringtoneUri,
    String? ringtoneTitle,
    bool? sendToVoicemail,
    bool clearRingtone = false,
  }) => ContactExtras(
    ringtoneUri: clearRingtone ? null : (ringtoneUri ?? this.ringtoneUri),
    ringtoneTitle: clearRingtone ? null : (ringtoneTitle ?? this.ringtoneTitle),
    defaultRingtoneTitle: defaultRingtoneTitle,
    sendToVoicemail: sendToVoicemail ?? this.sendToVoicemail,
    accountLabel: accountLabel,
    accountName: accountName,
  );
}

/// One row another app wrote onto the contact — «تماس صوتی با …», «پیام به …».
class ConnectedAppAction {
  /// Row id in `ContactsContract.Data`; what launching the action needs.
  final int dataId;
  final String mimeType;
  final String title;

  const ConnectedAppAction({
    required this.dataId,
    required this.mimeType,
    required this.title,
  });

  factory ConnectedAppAction.fromMap(Map<String, dynamic> map) =>
      ConnectedAppAction(
        dataId: (map['dataId'] as num?)?.toInt() ?? 0,
        mimeType: map['mimeType'] as String? ?? '',
        title: map['title'] as String? ?? '',
      );
}

/// Another app's rows on this contact — «برنامه‌های متصل» in Google Contacts.
class ConnectedApp {
  /// Empty when package visibility hid the owning app; the entry is still
  /// rendered, its actions still launch.
  final String packageName;
  final String label;
  final Uint8List? icon;
  final List<ConnectedAppAction> actions;

  const ConnectedApp({
    required this.packageName,
    required this.label,
    this.icon,
    this.actions = const [],
  });

  factory ConnectedApp.fromMap(Map<String, dynamic> map) {
    final raw = (map['actions'] as List?) ?? const [];
    return ConnectedApp(
      packageName: map['package'] as String? ?? '',
      label: map['label'] as String? ?? '',
      icon: map['icon'] as Uint8List?,
      actions: [
        for (final a in raw)
          ConnectedAppAction.fromMap(Map<String, dynamic>.from(a as Map)),
      ].where((a) => a.title.isNotEmpty).toList(),
    );
  }
}
