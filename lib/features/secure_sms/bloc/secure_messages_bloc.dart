import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/services/deep_link_service.dart';
import 'package:communication_super_app/features/messages/services/native_sms_service.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

import '../services/secure_identities.dart';
import 'package:communication_super_app/features/hidden/repositories/hidden_contacts_repository.dart';
import 'package:communication_super_app/features/secure/repositories/secure_group_store.dart';

import '../services/hidden_sms_source.dart';
import '../services/secure_messenger.dart';

// ── Events ───────────────────────────────────────────────────────────────────

sealed class SecureMessagesEvent {
  const SecureMessagesEvent();
}

class _SectionChanged extends SecureMessagesEvent {
  const _SectionChanged(this.unlocked);
  final bool unlocked;
}

/// The native receiver parked an encrypted SMS.
class _Arrived extends SecureMessagesEvent {
  const _Arrived();
}

/// The engine changed a conversation ([phone]) or the list (null).
class _Changed extends SecureMessagesEvent {
  const _Changed(this.phone);
  final String? phone;
}

/// A timed message's time is up (row 16).
class _Expire extends SecureMessagesEvent {
  const _Expire();
}

class _Status extends SecureMessagesEvent {
  const _Status(this.id, this.status);
  final String id;
  final String status;
}

class SecureOpenThread extends SecureMessagesEvent {
  const SecureOpenThread(this.phone);
  final String phone;
}

class SecureCloseThread extends SecureMessagesEvent {
  const SecureCloseThread(this.phone);
  final String phone;
}

class SecureSendText extends SecureMessagesEvent {
  const SecureSendText(this.text, {this.deleteAfterSeen = false, this.ttl});
  final String text;
  final bool deleteAfterSeen;

  /// A timed message (row 16): its lifetime in seconds.
  final int? ttl;
}

class SecureRetry extends SecureMessagesEvent {
  const SecureRetry(this.id);
  final String id;
}

class SecureDeleteForBoth extends SecureMessagesEvent {
  const SecureDeleteForBoth(this.id);
  final String id;
}

class SecureDeleteLocally extends SecureMessagesEvent {
  const SecureDeleteLocally(this.id);
  final String id;
}

class SecureDeleteConversation extends SecureMessagesEvent {
  const SecureDeleteConversation(this.phone);
  final String phone;
}

/// Whether this phone holds a key, for «گفتگوی رمز».
class SecureLoadPeers extends SecureMessagesEvent {
  const SecureLoadPeers();
}

/// How to reach [number] — typed, or picked from the address book as [name]
/// (`SecureIdentities.forNumber`).
class SecureLookupNumber extends SecureMessagesEvent {
  const SecureLookupNumber(this.number, {this.name});
  final String number;
  final String? name;
}

/// «دوباره تلاش»: a new session request to [phone] (`retryChannel`).
class SecureRetryChannel extends SecureMessagesEvent {
  const SecureRetryChannel(this.phone);
  final String phone;
}

/// «پیام رمز» on a hidden contact: their encrypted conversation, started
/// over our certificate when there is none yet.
class SecureStartEncrypted extends SecureMessagesEvent {
  const SecureStartEncrypted(this.phone, this.name);
  final String phone;
  final String name;
}

class SecureStartConversation extends SecureMessagesEvent {
  const SecureStartConversation(this.peer);
  final SecurePeer peer;
}

/// «پیامک» on a hidden contact: their plain-SMS thread (phase G), kept apart
/// from any encrypted conversation with [phone].
class SecureOpenWith extends SecureMessagesEvent {
  const SecureOpenWith(this.phone, this.name);
  final String phone;
  final String name;
}

/// A contact just hidden: their SMS history moves into the section. [done]
/// completes true once it is stored — only then may the original go.
class SecureImportHistory extends SecureMessagesEvent {
  const SecureImportHistory(this.phone, this.name, this.history, {this.done});
  final String phone;
  final String name;
  final List<({bool outgoing, String body, int timestamp})> history;
  final Completer<bool>? done;
}

/// A hidden contact was renamed.
class SecureRenamePeer extends SecureMessagesEvent {
  const SecureRenamePeer(this.phones, this.name);
  final List<String> phones;
  final String name;
}

// ── Groups (matrix row 14) ──────────────────────────────────────────────────

class SecureOpenGroup extends SecureMessagesEvent {
  const SecureOpenGroup(this.id);
  final String id;
}

class SecureCloseGroup extends SecureMessagesEvent {
  const SecureCloseGroup(this.id);
  final String id;
}

class SecureSendGroupText extends SecureMessagesEvent {
  const SecureSendGroupText(
    this.text, {
    this.deleteAfterSeen = false,
    this.ttl,
  });
  final String text;
  final bool deleteAfterSeen;
  final int? ttl;
}

class SecureCreateGroup extends SecureMessagesEvent {
  const SecureCreateGroup(this.name, this.mode, this.members);
  final String name;
  final SecureGroupMode mode;
  final List<SecurePeer> members;
}

class SecureEditGroup extends SecureMessagesEvent {
  const SecureEditGroup(this.id, this.name, this.members);
  final String id;
  final String name;
  final List<SecurePeer> members;
}

class SecureDeleteGroup extends SecureMessagesEvent {
  const SecureDeleteGroup(this.id);
  final String id;
}

class SecureGroupDeleteForAll extends SecureMessagesEvent {
  const SecureGroupDeleteForAll(this.id);
  final String id;
}

class SecureGroupDeleteLocally extends SecureMessagesEvent {
  const SecureGroupDeleteLocally(this.id);
  final String id;
}

class SecureRetryGroupMessage extends SecureMessagesEvent {
  const SecureRetryGroupMessage(this.id);
  final String id;
}

/// Who a group can be made of: everyone already talked to encrypted and the
/// hidden contacts; with [groupId], that group's members too.
class SecureLoadGroupCandidates extends SecureMessagesEvent {
  const SecureLoadGroupCandidates({this.groupId});
  final String? groupId;
}

/// Numbers picked from the address book for a group: added to the
/// candidates, each as [name].
class SecureAddGroupCandidates extends SecureMessagesEvent {
  const SecureAddGroupCandidates(this.picked);
  final List<({String phone, String name})> picked;
}

/// «متن پوششی» (row 31, organization edition): `fa`, `en` or null (off).
class SecureSetCover extends SecureMessagesEvent {
  const SecureSetCover(this.mode);
  final String? mode;
}

/// The SIM encrypted SMS go out on (null: the phone's default SMS SIM).
class SecureSetSim extends SecureMessagesEvent {
  const SecureSetSim(this.subscriptionId);
  final int? subscriptionId;
}

class SecureSetReceipts extends SecureMessagesEvent {
  const SecureSetReceipts(this.on);
  final bool on;
}

// ── State ────────────────────────────────────────────────────────────────────

enum SecureMessagesStatus { locked, loading, ready }

class SecureMessagesState extends Equatable {
  const SecureMessagesState({
    this.status = SecureMessagesStatus.locked,
    this.conversations = const [],
    this.openPhone,
    this.openMessages = const [],
    this.handshakePending = false,
    this.channel = const SecureChannelInfo(),
    this.hasCert = false,
    this.lookup,
    this.lookupSeq = 0,
    this.startedPhone,
    this.startedSeq = 0,
    this.sendsReceipts = true,
    this.cover,
    this.smsSim,
    this.groups = const [],
    this.names = const {},
    this.openGroupId,
    this.openGroupMessages = const [],
    this.candidates = const [],
    this.startedGroupId,
    this.startedGroupSeq = 0,
  });

  final SecureMessagesStatus status;
  final List<SecureConversation> conversations;

  /// The conversation on screen, and its messages.
  final String? openPhone;
  final List<SecureMessage> openMessages;

  /// The open conversation has no session yet: its first message waits for
  /// the handshake.
  final bool handshakePending;

  /// The open conversation's secure channel — what its screen says about a
  /// request nobody answered, one that did not go out, or a stalled upgrade.
  final SecureChannelInfo channel;

  /// We hold a key: any mobile number can be written to encrypted.
  final bool hasCert;

  /// Result of [SecureLookupNumber] (empty: the number cannot be reached);
  /// bumped seq per answer.
  final List<SecurePeer>? lookup;
  final int lookupSeq;

  /// The conversation [SecureStartConversation] created, for navigation.
  final String? startedPhone;
  final int startedSeq;

  final bool sendsReceipts;

  /// «متن پوششی»: `fa`, `en` or null.
  final String? cover;

  /// The SIM encrypted SMS go out on; null = the phone's default.
  final int? smsSim;

  final List<SecureGroup> groups;

  /// Number → name of every conversation, for group senders and members.
  final Map<String, String> names;

  /// The group on screen, and its messages.
  final String? openGroupId;
  final List<SecureGroupMessage> openGroupMessages;

  /// [SecureLoadGroupCandidates]' answer.
  final List<SecurePeer> candidates;

  /// The group [SecureCreateGroup] made, for navigation.
  final String? startedGroupId;
  final int startedGroupSeq;

  int get totalUnread =>
      conversations.fold(0, (sum, c) => sum + c.unread) +
      groups.fold(0, (sum, g) => sum + g.unread);

  SecureGroup? get openGroup =>
      groups.where((g) => g.id == openGroupId).firstOrNull;

  String nameOf(String phone) => names[phone] ?? phone;

  SecureMessagesState copyWith({
    SecureMessagesStatus? status,
    List<SecureConversation>? conversations,
    String? openPhone,
    bool clearOpen = false,
    List<SecureMessage>? openMessages,
    bool? handshakePending,
    SecureChannelInfo? channel,
    bool? hasCert,
    List<SecurePeer>? lookup,
    String? startedPhone,
    bool? sendsReceipts,
    String? cover,
    bool clearCover = false,
    int? smsSim,
    bool clearSmsSim = false,
    List<SecureGroup>? groups,
    Map<String, String>? names,
    String? openGroupId,
    bool clearOpenGroup = false,
    List<SecureGroupMessage>? openGroupMessages,
    List<SecurePeer>? candidates,
    String? startedGroupId,
  }) => SecureMessagesState(
    status: status ?? this.status,
    conversations: conversations ?? this.conversations,
    openPhone: clearOpen ? null : (openPhone ?? this.openPhone),
    openMessages: clearOpen ? const [] : (openMessages ?? this.openMessages),
    handshakePending: clearOpen
        ? false
        : (handshakePending ?? this.handshakePending),
    channel: clearOpen ? const SecureChannelInfo() : (channel ?? this.channel),
    hasCert: hasCert ?? this.hasCert,
    lookup: lookup ?? this.lookup,
    lookupSeq: lookup == null ? lookupSeq : lookupSeq + 1,
    startedPhone: startedPhone ?? this.startedPhone,
    startedSeq: startedPhone == null ? startedSeq : startedSeq + 1,
    sendsReceipts: sendsReceipts ?? this.sendsReceipts,
    cover: clearCover ? null : cover ?? this.cover,
    smsSim: clearSmsSim ? null : smsSim ?? this.smsSim,
    groups: groups ?? this.groups,
    names: names ?? this.names,
    openGroupId: clearOpenGroup ? null : (openGroupId ?? this.openGroupId),
    openGroupMessages: clearOpenGroup
        ? const []
        : (openGroupMessages ?? this.openGroupMessages),
    candidates: candidates ?? this.candidates,
    startedGroupId: startedGroupId ?? this.startedGroupId,
    startedGroupSeq: startedGroupId == null
        ? startedGroupSeq
        : startedGroupSeq + 1,
  );

  @override
  List<Object?> get props => [
    status,
    conversations,
    openPhone,
    openMessages,
    handshakePending,
    channel,
    hasCert,
    lookupSeq,
    startedSeq,
    sendsReceipts,
    cover,
    smsSim,
    groups,
    names,
    openGroupId,
    openGroupMessages,
    candidates,
    startedGroupSeq,
  ];
}

// ── Bloc ─────────────────────────────────────────────────────────────────────

/// «پیام‌های رمز»: encrypted conversations, alive only while the secure
/// section is open. It drains the native queue when the section opens and
/// whenever an encrypted SMS arrives while it is open, and forgets everything
/// the moment the section locks.
class SecureMessagesBloc
    extends Bloc<SecureMessagesEvent, SecureMessagesState> {
  SecureMessagesBloc({
    required SecureSessionBloc session,
    SecureMessenger? messenger,
    SecureMessageStore? store,
    SecureGroupStore? groups,
    HiddenContactsRepository? hidden,
    Stream<void>? arrivals,
    Stream<SmsStatusEvent>? statuses,
    Future<void> Function()? clearNotification,
    SmsCryptoService crypto = const SmsCryptoService(),
  }) : _store = store ?? SecureMessageStore(),
       _groups = groups ?? SecureGroupStore(),
       _hidden = hidden ?? HiddenContactsRepository(),
       _crypto = crypto,
       _clearNotification =
           clearNotification ??
           DeepLinkService.instance.clearSecureNotification,
       super(const SecureMessagesState()) {
    _messenger =
        messenger ??
        SecureMessenger(
          store: _store,
          groups: _groups,
          hidden: NativeHiddenSmsSource(),
        );
    _identities = SecureIdentities();

    on<_SectionChanged>(_onSection);
    on<_Arrived>(_onArrived);
    on<_Changed>(_onChanged);
    on<_Status>((e, emit) => _guard(() => _messenger.onStatus(e.id, e.status)));
    on<SecureRetryChannel>(
      (e, emit) => _guard(() => _messenger.retryChannel(e.phone)),
    );
    on<SecureStartEncrypted>(_onStartEncrypted);
    on<SecureOpenThread>(_onOpen);
    on<SecureCloseThread>(_onClose);
    on<SecureSendText>((e, emit) async {
      final phone = state.openPhone;
      if (phone == null || e.text.trim().isEmpty) return;
      // The thread decides, never the number: a plain thread is plain.
      final plain = SecureMessenger.isPlainThread(phone);
      await _guard(
        () => !plain
            ? _messenger.sendText(
                phone,
                e.text.trim(),
                deleteAfterSeen: e.deleteAfterSeen,
                ttl: e.ttl,
              )
            : _messenger.sendPlain(phone, e.text.trim()),
      );
    });
    on<SecureOpenWith>(_onOpenWith);
    on<SecureOpenGroup>(_onOpenGroup);
    on<SecureCloseGroup>((e, emit) async {
      if (_screenGroup == e.id) _screenGroup = null;
      if (state.openGroupId != e.id) return;
      emit(state.copyWith(clearOpenGroup: true));
      await _guard(() => _messenger.leaveGroupThread(e.id));
    });
    on<SecureSendGroupText>((e, emit) async {
      final id = state.openGroupId;
      if (id == null || e.text.trim().isEmpty) return;
      await _guard(
        () => _messenger.sendGroupText(
          id,
          e.text.trim(),
          deleteAfterSeen: e.deleteAfterSeen,
          ttl: e.ttl,
        ),
      );
    });
    on<_Expire>((e, emit) => _guard(_messenger.purgeExpired));
    on<SecureCreateGroup>((e, emit) async {
      if (!_open) return;
      String? id;
      await _guard(() async {
        id = await _messenger.createGroup(
          name: e.name.trim(),
          mode: e.mode,
          members: e.members,
        );
      });
      if (id != null) emit(state.copyWith(startedGroupId: id));
    });
    on<SecureEditGroup>(
      (e, emit) => _guard(
        () =>
            _messenger.editGroup(e.id, name: e.name.trim(), members: e.members),
      ),
    );
    on<SecureDeleteGroup>(
      (e, emit) => _guard(() => _messenger.deleteGroup(e.id)),
    );
    on<SecureGroupDeleteForAll>(
      (e, emit) => _guard(() => _messenger.deleteGroupMessageForAll(e.id)),
    );
    on<SecureGroupDeleteLocally>(
      (e, emit) => _guard(() => _messenger.deleteGroupMessageLocally(e.id)),
    );
    on<SecureRetryGroupMessage>(
      (e, emit) => _guard(() => _messenger.retryGroupMessage(e.id)),
    );
    on<SecureLoadGroupCandidates>(_onLoadCandidates);
    on<SecureAddGroupCandidates>(_onAddCandidates);
    on<SecureImportHistory>((e, emit) async {
      var stored = false;
      await _guard(() async {
        await _messenger.importPlainHistory(e.phone, e.name, e.history);
        stored = true;
      });
      e.done?.complete(stored);
    });
    on<SecureRenamePeer>(
      (e, emit) => _guard(() => _messenger.rename(e.phones, e.name)),
    );
    on<SecureRetry>((e, emit) => _guard(() => _messenger.retry(e.id)));
    on<SecureDeleteForBoth>(
      (e, emit) => _guard(() => _messenger.deleteForBoth(e.id)),
    );
    on<SecureDeleteLocally>(
      (e, emit) => _guard(() => _messenger.deleteLocally(e.id)),
    );
    on<SecureDeleteConversation>(
      (e, emit) => _guard(() => _messenger.deleteConversation(e.phone)),
    );
    on<SecureLoadPeers>(_onLoadPeers);
    on<SecureLookupNumber>(_onLookup);
    on<SecureStartConversation>(_onStart);
    on<SecureSetSim>((e, emit) async {
      await _guard(() => _messenger.setSmsSim(e.subscriptionId));
      emit(
        state.copyWith(
          smsSim: e.subscriptionId,
          clearSmsSim: e.subscriptionId == null,
        ),
      );
    });
    on<SecureSetCover>((e, emit) async {
      await _guard(() => _messenger.setCoverMode(e.mode));
      emit(state.copyWith(cover: e.mode, clearCover: e.mode == null));
    });
    on<SecureSetReceipts>((e, emit) async {
      await _guard(() => _messenger.setSendsSeenReceipts(e.on));
      emit(state.copyWith(sendsReceipts: e.on));
    });

    _subs = [
      session.stream
          .map((s) => s.isUnlocked)
          .distinct()
          .listen((u) => add(_SectionChanged(u))),
      (arrivals ?? NativeSmsService().onSecureArrived).listen(
        (_) => add(const _Arrived()),
      ),
      (statuses ?? NativeSmsService().onSmsStatus).listen(
        (s) => add(_Status(s.id, s.status)),
      ),
      _messenger.changes.listen((p) => add(_Changed(p))),
    ];
    if (session.state.isUnlocked) add(const _SectionChanged(true));
  }

  final SecureMessageStore _store;
  final SecureGroupStore _groups;
  final HiddenContactsRepository _hidden;
  final SmsCryptoService _crypto;
  final Future<void> Function() _clearNotification;
  late final SecureMessenger _messenger;
  late final SecureIdentities _identities;
  late final List<StreamSubscription<Object?>> _subs;

  /// Fires when the next timed message is due to go.
  Timer? _expiry;

  /// The conversation / group whose screen is up, kept across a lock: the
  /// section locks when the app goes to the background, the screen stays,
  /// and after the PIN it must show its messages again (it used to stay
  /// empty until it was left and reopened — found on the phone).
  String? _screenPhone;
  String? _screenGroup;

  bool get _open => state.status != SecureMessagesStatus.locked;

  /// Runs an engine call; a section that locked under it just ends the call.
  Future<void> _guard(Future<void> Function() call) async {
    if (!_open) return;
    try {
      await call();
    } on KeyBankLockedException {
      // Locked meanwhile: _SectionChanged(false) resets the state.
    } catch (e) {
      debugPrint('Secure messaging: ${e.runtimeType}');
    }
  }

  Future<void> _onSection(
    _SectionChanged e,
    Emitter<SecureMessagesState> emit,
  ) async {
    _messenger.reset();
    _identities.reset();
    if (!e.unlocked) {
      _expiry?.cancel();
      emit(const SecureMessagesState());
      return;
    }
    emit(state.copyWith(status: SecureMessagesStatus.loading));
    await _drain();
    // Whatever ran out while the section was locked goes before it is shown.
    await _guard(_messenger.purgeExpired);
    emit(state.copyWith(openPhone: _screenPhone, openGroupId: _screenGroup));
    await _reload(emit);
    final phone = _screenPhone;
    if (phone != null) {
      await _guard(() => _messenger.markSeen(phone));
      await _guard(() => _messenger.flush(phone));
    }
    final group = _screenGroup;
    if (group != null) await _guard(() => _messenger.markGroupSeen(group));
    try {
      final cover = await _messenger.coverMode();
      final sim = await _messenger.smsSim();
      emit(
        state.copyWith(
          sendsReceipts: await _messenger.sendsSeenReceipts(),
          cover: cover == 'fa' || cover == 'en' ? cover : null,
          clearCover: cover != 'fa' && cover != 'en',
          smsSim: sim != null && sim >= 0 ? sim : null,
          clearSmsSim: sim == null || sim < 0,
        ),
      );
    } on KeyBankLockedException {
      emit(const SecureMessagesState());
    }
  }

  Future<void> _drain() async {
    try {
      await _messenger.drain();
      await _clearNotification();
    } on KeyBankLockedException {
      // Locked meanwhile.
    } catch (e) {
      debugPrint('Draining encrypted SMS failed: ${e.runtimeType}');
    }
  }

  Future<void> _onArrived(_Arrived e, Emitter<SecureMessagesState> emit) async {
    if (_open) await _drain();
  }

  Future<void> _reload(Emitter<SecureMessagesState> emit) async {
    try {
      final conversations = await _store.conversations();
      final phone = state.openPhone;
      final group = state.openGroupId;
      emit(
        state.copyWith(
          status: SecureMessagesStatus.ready,
          conversations: conversations,
          groups: await _groups.groups(),
          names: await _store.names(),
          openGroupMessages: group == null
              ? null
              : await _groups.messages(group),
          openMessages: phone == null ? null : await _store.messages(phone),
          handshakePending: phone == null ? null : await _pending(phone),
          channel: phone == null ? null : await _store.channelInfo(phone),
        ),
      );
      await _armExpiry();
    } on KeyBankLockedException {
      emit(const SecureMessagesState());
    }
  }

  Future<void> _armExpiry() async {
    _expiry?.cancel();
    final at = await _store.nextExpiry();
    if (at == null || isClosed) return;
    final wait = at - DateTime.now().millisecondsSinceEpoch;
    _expiry = Timer(
      Duration(milliseconds: wait < 0 ? 0 : wait + 50),
      () => isClosed ? null : add(const _Expire()),
    );
  }

  Future<bool> _pending(String phone) => _store.awaitingSession(phone);

  Future<void> _onChanged(_Changed e, Emitter<SecureMessagesState> emit) async {
    if (!_open) return;
    await _reload(emit);
    // Something arrived in the conversation on screen: it is seen now.
    final phone = state.openPhone;
    if (phone != null && e.phone == phone) {
      final unseen = state.openMessages.any(
        (m) => !m.outgoing && m.seenAt == null,
      );
      if (unseen) await _guard(() => _messenger.markSeen(phone));
    }
    final group = state.openGroupId;
    if (group != null &&
        state.openGroupMessages.any((m) => !m.outgoing && m.seenAt == null)) {
      await _guard(() => _messenger.markGroupSeen(group));
    }
  }

  Future<void> _onOpen(
    SecureOpenThread e,
    Emitter<SecureMessagesState> emit,
  ) async {
    _screenPhone = e.phone;
    if (!_open) return;
    emit(state.copyWith(openPhone: e.phone));
    await _reload(emit);
    await _guard(() => _messenger.markSeen(e.phone));
    // A message still queued from an earlier visit goes out now if it can.
    await _guard(() => _messenger.flush(e.phone));
  }

  Future<void> _onClose(
    SecureCloseThread e,
    Emitter<SecureMessagesState> emit,
  ) async {
    if (_screenPhone == e.phone) _screenPhone = null;
    if (state.openPhone != e.phone) return;
    emit(state.copyWith(clearOpen: true));
    await _guard(() => _messenger.leaveConversation(e.phone));
  }

  Future<void> _onLoadPeers(
    SecureLoadPeers e,
    Emitter<SecureMessagesState> emit,
  ) async {
    if (!_open) return;
    _identities.reset(); // the key bank may have changed
    try {
      emit(state.copyWith(hasCert: await _identities.ownCert() != null));
    } on KeyBankLockedException {
      emit(const SecureMessagesState());
    }
  }

  Future<void> _onLookup(
    SecureLookupNumber e,
    Emitter<SecureMessagesState> emit,
  ) async {
    if (!_open) return;
    _identities.reset();
    try {
      final phone = await _crypto.canonicalPhone(e.number);
      final peer = phone == null
          ? null
          : await _identities.forNumber(phone, name: e.name);
      emit(state.copyWith(lookup: [?peer]));
    } on KeyBankLockedException {
      emit(const SecureMessagesState());
    }
  }

  Future<void> _onStart(
    SecureStartConversation e,
    Emitter<SecureMessagesState> emit,
  ) async {
    if (!_open) return;
    // A conversation that already has its keys is just opened: starting it
    // again would forget the peer's certificate.
    final existing = await _store.conversation(e.peer.phone);
    if (existing == null || !existing.encrypted) {
      await _guard(() => _messenger.startConversation(e.peer));
    }
    emit(state.copyWith(startedPhone: e.peer.phone));
  }

  Future<void> _onOpenGroup(
    SecureOpenGroup e,
    Emitter<SecureMessagesState> emit,
  ) async {
    _screenGroup = e.id;
    if (!_open) return;
    emit(state.copyWith(openGroupId: e.id));
    await _reload(emit);
    await _guard(() => _messenger.markGroupSeen(e.id));
  }

  Future<void> _onLoadCandidates(
    SecureLoadGroupCandidates e,
    Emitter<SecureMessagesState> emit,
  ) async {
    if (!_open) return;
    _identities.reset();
    try {
      // Everyone already talked to encrypted, and the hidden contacts; the
      // screen adds whoever else is picked from the address book.
      final byPhone = <String, SecurePeer>{};
      for (final c in await _store.conversations()) {
        if (!c.encrypted) continue;
        final own =
            await _identities.ownByKeyId(c.ownKeyId!) ??
            await _identities.ownCert();
        if (own == null) continue;
        byPhone[c.phone] = SecurePeer(
          name: c.name,
          phone: c.phone,
          keyId: c.peerKeyId!,
          own: own,
        );
      }
      for (final c in await _hidden.contacts()) {
        for (final n in c.numbers.where((n) => n.textable)) {
          final known = byPhone[n.phone];
          if (known != null) {
            byPhone[n.phone] = known.named(c.name);
            continue;
          }
          final peer = await _identities.forNumber(n.phone, name: c.name);
          if (peer != null) byPhone[n.phone] = peer;
        }
      }
      // A group being edited keeps every member it has, known by the key id
      // the group holds for them (empty until they answered).
      final groupId = e.groupId;
      final own = await _identities.ownCert();
      if (groupId != null && own != null) {
        final names = await _store.names();
        for (final m in await _groups.allMembers(groupId)) {
          if (m.removed || byPhone.containsKey(m.phone)) continue;
          byPhone[m.phone] = SecurePeer(
            name: names[m.phone] ?? m.phone,
            phone: m.phone,
            keyId: m.keyId,
            own: own,
          );
        }
      }
      emit(state.copyWith(candidates: _sorted(byPhone.values)));
    } on KeyBankLockedException {
      emit(const SecureMessagesState());
    }
  }

  Future<void> _onAddCandidates(
    SecureAddGroupCandidates e,
    Emitter<SecureMessagesState> emit,
  ) async {
    if (!_open) return;
    try {
      final byPhone = {for (final p in state.candidates) p.phone: p};
      for (final picked in e.picked) {
        final phone = await _crypto.canonicalPhone(picked.phone);
        if (phone == null || byPhone.containsKey(phone)) continue;
        final peer = await _identities.forNumber(phone, name: picked.name);
        if (peer != null) byPhone[phone] = peer;
      }
      emit(state.copyWith(candidates: _sorted(byPhone.values)));
    } on KeyBankLockedException {
      emit(const SecureMessagesState());
    }
  }

  Future<void> _onStartEncrypted(
    SecureStartEncrypted e,
    Emitter<SecureMessagesState> emit,
  ) async {
    if (!_open) return;
    try {
      final existing = await _store.conversation(e.phone);
      if (existing == null || !existing.encrypted) {
        _identities.reset();
        final peer = await _identities.forNumber(e.phone, name: e.name);
        if (peer == null) {
          emit(state.copyWith(lookup: const []));
          return;
        }
        await _messenger.startConversation(peer);
      }
    } on KeyBankLockedException {
      return;
    }
    emit(state.copyWith(startedPhone: e.phone));
  }

  static List<SecurePeer> _sorted(Iterable<SecurePeer> peers) =>
      peers.toList()..sort((a, b) => a.name.compareTo(b.name));

  Future<void> _onOpenWith(
    SecureOpenWith e,
    Emitter<SecureMessagesState> emit,
  ) async {
    if (!_open) return;
    // «پیامک» on a hidden contact: their plain thread, always — an
    // encrypted conversation is started from «گفتگوی رمز», and the two are
    // never one.
    final String thread;
    try {
      thread = await _messenger.startPlainConversation(e.phone, e.name);
    } on KeyBankLockedException {
      return;
    } catch (err) {
      debugPrint('Opening a hidden conversation failed: ${err.runtimeType}');
      return;
    }
    emit(state.copyWith(startedPhone: thread));
  }

  @override
  Future<void> close() async {
    _expiry?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _messenger.dispose();
    return super.close();
  }
}
