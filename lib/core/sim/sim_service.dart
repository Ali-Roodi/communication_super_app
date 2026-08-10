import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'sim_card.dart';

/// The app's single source of truth for "which SIMs are in this phone".
///
/// It is a singleton with a **static cache** on purpose: a list row, a bubble
/// caption and a call-log tile all need a SIM label inside `build`, and making
/// each of them await a platform channel would rebuild every one of them a
/// frame later (and hammer the channel once per row). [cached] answers those
/// synchronously; everything that can await goes through [load].
class SimService {
  SimService._();

  static final SimService instance = SimService._();

  static const MethodChannel _method = MethodChannel(
    'com.example.communication_super_app/sim',
  );
  static const EventChannel _events = EventChannel(
    'com.example.communication_super_app/sim_events',
  );

  static List<SimCard> _cache = const <SimCard>[];
  static SimDefaults _defaults = const SimDefaults.unknown();

  final StreamController<List<SimCard>> _controller =
      StreamController<List<SimCard>>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  bool _listening = false;

  /// Last known roster. Empty until the first [load] — which, on a device that
  /// refused READ_PHONE_STATE, it stays. Empty must therefore read as "single,
  /// unknown SIM": no chip, no picker, send with the system default.
  static List<SimCard> get cached => _cache;

  static SimDefaults get defaults => _defaults;

  /// True only when the phone really has two or more active SIMs. **Every**
  /// SIM affordance in the UI hangs off this — on a single-SIM phone the app
  /// must look exactly as it did before, which is what Google Messages and
  /// Google Phone do.
  static bool get isMultiSim => _cache.length > 1;

  /// Roster changes (SIM inserted, removed, renamed, or a permission granted).
  Stream<List<SimCard>> get onChanged => _controller.stream;

  /// Subscribes to the native roster stream. Safe to call repeatedly — the
  /// second call is a no-op, mirroring [NativeSmsService.initialize]; a second
  /// subscription would tear the EventChannel down and rebuild it.
  void initialize() {
    if (_listening) return;
    _listening = true;
    try {
      _subscription = _events.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is! List) return;
          _publish(_parse(event));
        },
        onError: (Object error) {
          debugPrint('SIM event stream error: $error');
        },
        cancelOnError: false,
      );
    } catch (e) {
      _listening = false;
      debugPrint('SIM event stream failed: $e');
    }
  }

  /// Reads the roster and the system defaults once.
  ///
  /// Never throws: a phone with no telephony, or one where the permission was
  /// refused, answers an empty list and the app carries on as single-SIM.
  Future<List<SimCard>> load() async {
    try {
      final raw = await _method.invokeMethod<List<dynamic>>('getSubscriptions');
      final sims = _parse(raw ?? const []);
      final defaults = await _method.invokeMapMethod<String, dynamic>(
        'getDefaults',
      );
      if (defaults != null) _defaults = SimDefaults.fromMap(defaults);
      await loadPhoneAccounts();
      _publish(sims);
      // A direct load satisfies ensureLoaded too — otherwise the permission
      // gate's re-read and the call-log sync would each pay for their own.
      _ensureLoaded ??= Future<void>.value();
      return sims;
    } on PlatformException catch (e) {
      debugPrint('getSubscriptions failed: ${e.code} - ${e.message}');
      return _cache;
    } catch (e) {
      debugPrint('getSubscriptions failed: $e');
      return _cache;
    }
  }

  /// `PhoneAccount` id → subscription id.
  ///
  /// The call log records the *account id string* of the SIM a call used, and
  /// there is no public API that maps it back — telephony's id is the
  /// subscription id on modern AOSP and the ICC ID on older/OEM builds. The
  /// mapping is read once (it has at most two entries) and cached, because the
  /// alternative is a platform call per call-log row.
  static Map<String, int> _accountToSubscription = const {};

  static int? subscriptionForAccountId(String? accountId) {
    if (accountId == null || accountId.isEmpty) return null;
    final direct = _accountToSubscription[accountId];
    if (direct != null) return direct;
    // A VoIP app's calls live in the same log under their own account ids;
    // answering null for those is correct — they came from no SIM.
    return null;
  }

  /// Guarantees the roster and the account mapping have been read at least
  /// once, without re-reading them on every call.
  ///
  /// The call-log sync needs this: it maps a row's PhoneAccount id to a
  /// subscription and *persists the result*, so running before the mapping
  /// exists writes a null SIM onto every call and the badge never appears
  /// until the next sync. `SimBloc` loads the roster at startup, but the
  /// call-log sync can (and does) win that race on a cold start.
  Future<void> ensureLoaded() {
    return _ensureLoaded ??= load().then((_) {});
  }

  Future<void>? _ensureLoaded;

  /// Reads the account↔subscription mapping. Cheap and idempotent; called
  /// alongside [load].
  Future<void> loadPhoneAccounts() async {
    try {
      final rows = await _method.invokeMethod<List<dynamic>>('getPhoneAccounts');
      if (rows == null) return;
      final map = <String, int>{};
      for (final row in rows) {
        if (row is! Map) continue;
        final id = row['accountId'] as String?;
        final sub = (row['subscriptionId'] as num?)?.toInt();
        if (id != null && id.isNotEmpty && sub != null && sub >= 0) {
          map[id] = sub;
        }
      }
      _accountToSubscription = Map<String, int>.unmodifiable(map);
    } catch (e) {
      debugPrint('getPhoneAccounts failed: $e');
    }
  }

  List<SimCard> _parse(List<dynamic> raw) {
    final sims = <SimCard>[];
    for (final item in raw) {
      if (item is! Map) continue;
      sims.add(SimCard.fromMap(Map<String, dynamic>.from(item)));
    }
    sims.sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    return sims;
  }

  void _publish(List<SimCard> sims) {
    // Identical rosters are dropped: the native listener fires several times
    // for one card insertion (radio up, records loaded, name resolved) and
    // every one of them would otherwise rebuild the contacts list.
    if (listEquals(_cache, sims)) return;
    _cache = List<SimCard>.unmodifiable(sims);
    if (!_controller.isClosed) _controller.add(_cache);
  }

  /// The SIM behind a subscription id, or null when it is unknown — a stored
  /// preference pointing at a card that has since been removed, or a message
  /// that predates dual-SIM support.
  static SimCard? byId(int? subscriptionId) {
    if (subscriptionId == null ||
        subscriptionId == SimCard.invalidSubscriptionId) {
      return null;
    }
    for (final sim in _cache) {
      if (sim.subscriptionId == subscriptionId) return sim;
    }
    return null;
  }

  /// The SIM a send/dial should use when the user has expressed no preference:
  /// the system default when one is pinned, otherwise the only SIM, otherwise
  /// null (which means "ask" on a dual-SIM phone and "let the platform pick"
  /// on a single-SIM one).
  static SimCard? defaultFor(SimUse use) {
    final pinned = byId(switch (use) {
      SimUse.sms => _defaults.sms,
      SimUse.voice => _defaults.voice,
    });
    if (pinned != null) return pinned;
    return _cache.length == 1 ? _cache.first : null;
  }

  @visibleForTesting
  static void debugSetRoster(
    List<SimCard> sims, {
    SimDefaults? defaults,
    Map<String, int>? accounts,
  }) {
    _cache = List<SimCard>.unmodifiable(sims);
    if (defaults != null) _defaults = defaults;
    if (accounts != null) {
      _accountToSubscription = Map<String, int>.unmodifiable(accounts);
    }
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _listening = false;
  }
}

enum SimUse { sms, voice }
