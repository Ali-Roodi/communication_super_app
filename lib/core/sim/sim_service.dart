import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Bumped whenever [cached] or [defaults] changes — a card inserted or
  /// removed, a name resolved, READ_PHONE_STATE granted, the system default
  /// re-pinned.
  ///
  /// Every SIM affordance reads the static roster synchronously inside `build`
  /// (a bubble's badge cannot await a channel), so nothing in the element tree
  /// depends on it and nothing rebuilt when a second card went in: the app
  /// stayed single-SIM-shaped until it was killed and reopened. Screens that
  /// keep a SIM surface on screen wrap it in [SimAware], which listens here.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

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
          if (!_publish(_parse(event))) return;
          // The roster really moved. Everything *derived* from it is now stale
          // too and none of it rides on this event: which card the system has
          // pinned for SMS and for voice, and the PhoneAccount↔subscription
          // map every call-log row is stamped from. Re-read both.
          //
          // This is the second half of "the app only notices a new SIM after a
          // restart": the roster updated live, while `defaults` still said
          // «single SIM, nothing pinned» and the account map still had one
          // entry, so the picker had nothing to pick and every new call was
          // logged with no SIM.
          unawaited(_refreshDerived());
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
    // The pinned defaults are not part of the roster and no event carries
    // them, so a default re-pinned in Android's settings reached nothing:
    // the dialer's process outlives the trip to Settings, and the old card
    // went on being dialled and texted from. Coming back is the only way to
    // have changed it, so coming back is when it is re-read.
    try {
      _lifecycle ??= AppLifecycleListener(
        onResume: () => unawaited(refreshDefaults()),
      );
    } catch (e) {
      debugPrint('SIM lifecycle listener failed: $e');
    }
  }

  AppLifecycleListener? _lifecycle;

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
      if (defaults != null) {
        final parsed = SimDefaults.fromMap(defaults);
        if (parsed != _defaults) {
          _defaults = parsed;
          revision.value++;
        }
      }
      await loadPhoneAccounts();
      await _loadAppDefaults();
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
      final rows = await _method.invokeMethod<List<dynamic>>(
        'getPhoneAccounts',
      );
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

  /// Re-reads what the roster event does not carry: the system's pinned
  /// defaults and the PhoneAccount↔subscription map.
  Future<void> _refreshDerived() async {
    await refreshDefaults();
    await loadPhoneAccounts();
  }

  /// Re-reads which cards Android has pinned for SMS and for voice — one
  /// cheap platform call. [resolveVoiceSim] awaits it before every dial, and
  /// it runs whenever the app comes back to the foreground.
  Future<void> refreshDefaults() async {
    try {
      final defaults = await _method.invokeMapMethod<String, dynamic>(
        'getDefaults',
      );
      if (defaults != null) {
        final parsed = SimDefaults.fromMap(defaults);
        if (parsed != _defaults) {
          _defaults = parsed;
          revision.value++;
        }
      }
    } catch (e) {
      debugPrint('getDefaults failed: $e');
    }
  }

  /// Returns true when the roster actually changed.
  bool _publish(List<SimCard> sims) {
    // Identical rosters are dropped: the native listener fires several times
    // for one card insertion (radio up, records loaded, name resolved) and
    // every one of them would otherwise rebuild the contacts list.
    if (listEquals(_cache, sims)) return false;
    _cache = List<SimCard>.unmodifiable(sims);
    if (!_controller.isClosed) _controller.add(_cache);
    // Widgets read [cached] / [isMultiSim] synchronously inside `build` — a
    // SIM badge may not await a platform channel — so the roster changing is
    // not something the element tree can notice by itself. This is how the
    // surfaces that are *already on screen* when a card goes in find out; see
    // [SimAware].
    revision.value++;
    return true;
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

  /// The card an ordinary send or dial uses when nothing more specific —
  /// a pick for this one call, the contact's or the conversation's own card —
  /// applies: the app's own default (Settings → «سیم‌کارت‌ها»), else the
  /// phone's, else the only SIM. Null means "ask" on a dual-SIM phone and
  /// "let the platform pick" on a single-SIM one.
  static SimCard? defaultFor(SimUse use) {
    final app = appDefault(use);
    if (app == appAsk) return null;
    final own = byId(app);
    if (own != null) return own;
    return phoneDefault(use) ?? (_cache.length == 1 ? _cache.first : null);
  }

  /// The card the phone itself has pinned for [use], or null.
  static SimCard? phoneDefault(SimUse use) => byId(switch (use) {
    SimUse.sms => _defaults.sms,
    SimUse.voice => _defaults.voice,
  });

  // ── The app's own default card (Settings → «سیم‌کارت‌ها») ──────────────────
  //
  // [appFollowPhone] until the user picks one, so the app starts out doing
  // exactly what the phone's settings say. A stored card that is no longer in
  // the phone reads as "follow the phone" too. Mirrored natively
  // (`setAppDefaults` → `SimRegistry`), because the missed-call «تماس»,
  // the notification quick reply and a call another app starts are all placed
  // with no Flutter engine.

  /// Follow the phone's own default.
  static const int appFollowPhone = -1;

  /// Calls only: ask on every dial.
  static const int appAsk = -2;

  static const _voiceKey = 'sim_default_voice';
  static const _smsKey = 'sim_default_sms';
  static int _appVoice = appFollowPhone;
  static int _appSms = appFollowPhone;

  /// The stored choice for [use]: a subscription id, [appFollowPhone] or
  /// (voice only) [appAsk].
  static int appDefault(SimUse use) =>
      use == SimUse.voice ? _appVoice : _appSms;

  Future<void> _loadAppDefaults() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _appVoice = prefs.getInt(_voiceKey) ?? appFollowPhone;
      _appSms = prefs.getInt(_smsKey) ?? appFollowPhone;
    } catch (e) {
      debugPrint('SIM defaults read failed: $e');
    }
    await _mirrorAppDefaults();
  }

  /// Stores the app's default card for [use] — a subscription id,
  /// [appFollowPhone] or (voice) [appAsk].
  Future<void> setAppDefault(SimUse use, int value) async {
    if (use == SimUse.sms && value == appAsk) return;
    final prefs = await SharedPreferences.getInstance();
    if (use == SimUse.voice) {
      _appVoice = value;
      await prefs.setInt(_voiceKey, value);
    } else {
      _appSms = value;
      await prefs.setInt(_smsKey, value);
    }
    await _mirrorAppDefaults();
    revision.value++;
  }

  Future<void> _mirrorAppDefaults() async {
    try {
      await _method.invokeMethod<void>('setAppDefaults', {
        'voice': _appVoice,
        'sms': _appSms,
      });
    } catch (e) {
      debugPrint('SIM defaults mirror failed: $e');
    }
  }

  /// How an ordinary dial of [number] would pick its card, asked of the
  /// native side — which places the call by the very same rule
  /// (`SimRegistry.routeFor`): the contact's own card, else the app's
  /// default, else the phone's, else a question. [CallRoute.sim] is that card
  /// when it is known.
  Future<CallRoute> callRoute(String number) async {
    if (!isMultiSim) return const CallRoute(CallRouteKind.single);
    await refreshDefaults();
    try {
      final map = await _method.invokeMapMethod<String, dynamic>('callRoute', {
        'number': number,
      });
      final kind = switch (map?['route']) {
        'live_call' => CallRouteKind.liveCall,
        'contact' => CallRouteKind.contact,
        'app' => CallRouteKind.app,
        'phone_default' => CallRouteKind.phoneDefault,
        'ask' => CallRouteKind.ask,
        _ => CallRouteKind.single,
      };
      return CallRoute(kind, byId((map?['subscriptionId'] as num?)?.toInt()));
    } catch (e) {
      debugPrint('callRoute failed: $e');
      // Unknown: ask rather than let telecom stall on «ask every time».
      return const CallRoute(CallRouteKind.ask);
    }
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
    _lifecycle?.dispose();
    _lifecycle = null;
    _listening = false;
  }
}

enum SimUse { sms, voice }

enum CallRouteKind { single, liveCall, contact, app, phoneDefault, ask }

/// See [SimService.callRoute].
class CallRoute {
  const CallRoute(this.kind, [this.sim]);
  final CallRouteKind kind;
  final SimCard? sim;

  /// Whether the dial has to ask which card.
  bool get asks => kind == CallRouteKind.ask;
}
