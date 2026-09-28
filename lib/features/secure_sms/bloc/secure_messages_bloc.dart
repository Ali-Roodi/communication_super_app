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
  const SecureSendText(this.text, {this.deleteAfterSeen = false});
  final String text;
  final bool deleteAfterSeen;
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

/// Loads who an encrypted conversation can be started with.
class SecureLoadPeers extends SecureMessagesEvent {
  const SecureLoadPeers();
}

/// The ways to reach a number typed by hand (passphrase groups).
class SecureLookupNumber extends SecureMessagesEvent {
  const SecureLookupNumber(this.number);
  final String number;
}

class SecureStartConversation extends SecureMessagesEvent {
  const SecureStartConversation(this.peer);
  final SecurePeer peer;
}

/// «پیام» on a hidden contact: their conversation — encrypted when the key
/// bank has a key for [phone], plain SMS otherwise (phase G).
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
  const SecureSendGroupText(this.text, {this.deleteAfterSeen = false});
  final String text;
  final bool deleteAfterSeen;
}

class SecureCreateGroup extends SecureMessagesEvent {
  const SecureCreateGroup(this.name, this.mode, this.members);
  final String name;
  final SecureGroupMode mode;
  final List<SecurePeer> members;
}

class SecureEditGroup extends SecureMessagesEvent {
  const SecureEditGroup(
    this.id,
    this.name,
    this.members, {
    this.keep = const [],
  });
  final String id;
  final String name;
  final List<SecurePeer> members;

  /// Members staying whose key is no longer in the bank.
  final List<String> keep;
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

/// Who a group can be made of: directory members, and hidden contacts the
/// key bank has a key for.
class SecureLoadGroupCandidates extends SecureMessagesEvent {
  const SecureLoadGroupCandidates();
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
    this.peers = const [],
    this.lookup,
    this.lookupSeq = 0,
    this.startedPhone,
    this.startedSeq = 0,
    this.sendsReceipts = true,
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

  /// Directory members an encrypted conversation can be started with.
  final List<SecurePeer> peers;

  /// Result of [SecureLookupNumber]; bumped seq per answer.
  final List<SecurePeer>? lookup;
  final int lookupSeq;

  /// The conversation [SecureStartConversation] created, for navigation.
  final String? startedPhone;
  final int startedSeq;

  final bool sendsReceipts;

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
    List<SecurePeer>? peers,
    List<SecurePeer>? lookup,
    String? startedPhone,
    bool? sendsReceipts,
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
    peers: peers ?? this.peers,
    lookup: lookup ?? this.lookup,
    lookupSeq: lookup == null ? lookupSeq : lookupSeq + 1,
    startedPhone: startedPhone ?? this.startedPhone,
    startedSeq: startedPhone == null ? startedSeq : startedSeq + 1,
    sendsReceipts: sendsReceipts ?? this.sendsReceipts,
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
    peers,
    lookupSeq,
    startedSeq,
    sendsReceipts,
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
    on<SecureOpenThread>(_onOpen);
    on<SecureCloseThread>(_onClose);
    on<SecureSendText>((e, emit) async {
      final phone = state.openPhone;
      if (phone == null || e.text.trim().isEmpty) return;
      final encrypted =
          state.conversations
              .where((c) => c.phone == phone)
              .firstOrNull
              ?.encrypted ??
          true;
      await _guard(
        () => encrypted
            ? _messenger.sendText(
                phone,
                e.text.trim(),
                deleteAfterSeen: e.deleteAfterSeen,
              )
            : _messenger.sendPlain(phone, e.text.trim()),
      );
    });
    on<SecureOpenWith>(_onOpenWith);
    on<SecureOpenGroup>(_onOpenGroup);
    on<SecureCloseGroup>((e, emit) async {
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
        ),
      );
    });
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
        () => _messenger.editGroup(
          e.id,
          name: e.name.trim(),
          members: e.members,
          keep: e.keep,
        ),
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
      emit(const SecureMessagesState());
      return;
    }
    emit(state.copyWith(status: SecureMessagesStatus.loading));
    await _drain();
    await _reload(emit);
    try {
      emit(state.copyWith(sendsReceipts: await _messenger.sendsSeenReceipts()));
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
        ),
      );
    } on KeyBankLockedException {
      emit(const SecureMessagesState());
    }
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
      emit(state.copyWith(peers: await _identities.directoryPeers()));
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
      emit(
        state.copyWith(
          lookup: phone == null ? const [] : await _identities.forNumber(phone),
        ),
      );
    } on KeyBankLockedException {
      emit(const SecureMessagesState());
    }
  }

  Future<void> _onStart(
    SecureStartConversation e,
    Emitter<SecureMessagesState> emit,
  ) async {
    if (!_open) return;
    await _guard(() => _messenger.startConversation(e.peer));
    emit(state.copyWith(startedPhone: e.peer.phone));
  }

  Future<void> _onOpenGroup(
    SecureOpenGroup e,
    Emitter<SecureMessagesState> emit,
  ) async {
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
      final byPhone = <String, SecurePeer>{
        for (final p in await _identities.directoryPeers()) p.phone: p,
      };
      for (final c in await _hidden.contacts()) {
        for (final n in c.numbers.where((n) => n.textable)) {
          final ways = await _identities.forNumber(n.phone);
          if (ways.isEmpty) continue;
          // The hidden contact's own name, whatever the directory calls them.
          final w = ways.first;
          byPhone[n.phone] = SecurePeer(
            name: c.name,
            phone: w.phone,
            publicKey: w.publicKey,
            keyId: w.keyId,
            source: w.source,
            sourceName: w.sourceName,
            own: w.own,
          );
        }
      }
      final list = byPhone.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      emit(state.copyWith(candidates: list));
    } on KeyBankLockedException {
      emit(const SecureMessagesState());
    }
  }

  Future<void> _onOpenWith(
    SecureOpenWith e,
    Emitter<SecureMessagesState> emit,
  ) async {
    if (!_open) return;
    try {
      if (await _store.conversation(e.phone) == null) {
        _identities.reset();
        final ways = await _identities.forNumber(e.phone);
        if (ways.isEmpty) {
          await _messenger.startPlainConversation(e.phone, e.name);
        } else {
          // A directory member before a group key: the first way is the
          // authority-issued one when there is one (forNumber's order).
          await _messenger.startConversation(ways.first);
        }
      } else {
        await _messenger.rename([e.phone], e.name);
      }
    } on KeyBankLockedException {
      return;
    } catch (err) {
      debugPrint('Opening a hidden conversation failed: ${err.runtimeType}');
      return;
    }
    emit(state.copyWith(startedPhone: e.phone));
  }

  @override
  Future<void> close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _messenger.dispose();
    return super.close();
  }
}
