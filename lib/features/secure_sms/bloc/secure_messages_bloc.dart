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

  int get totalUnread => conversations.fold(0, (sum, c) => sum + c.unread);

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
    Stream<void>? arrivals,
    Stream<SmsStatusEvent>? statuses,
    Future<void> Function()? clearNotification,
    SmsCryptoService crypto = const SmsCryptoService(),
  }) : _store = store ?? SecureMessageStore(),
       _crypto = crypto,
       _clearNotification =
           clearNotification ??
           DeepLinkService.instance.clearSecureNotification,
       super(const SecureMessagesState()) {
    _messenger = messenger ?? SecureMessenger(store: _store);
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
      await _guard(
        () => _messenger.sendText(
          phone,
          e.text.trim(),
          deleteAfterSeen: e.deleteAfterSeen,
        ),
      );
    });
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
      emit(
        state.copyWith(
          status: SecureMessagesStatus.ready,
          conversations: conversations,
          openMessages: phone == null ? null : await _store.messages(phone),
          handshakePending: phone == null ? null : await _pending(phone),
        ),
      );
    } on KeyBankLockedException {
      emit(const SecureMessagesState());
    }
  }

  Future<bool> _pending(String phone) async =>
      !(await _store.sessions(phone)).any((s) => !s.pending);

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

  @override
  Future<void> close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _messenger.dispose();
    return super.close();
  }
}
