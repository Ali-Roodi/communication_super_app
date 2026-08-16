import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'avatar_widget.dart';

/// A circular contact avatar that loads the device-contact thumbnail **lazily**,
/// by id, only when it scrolls into view.
///
/// Why this exists: the contact list used to hold the decoded thumbnail of
/// every contact in a static cache, which blew the heap on large address books.
/// This widget shows initials immediately (zero cost) and fetches the single
/// contact's thumbnail in the background, keeping only a small bounded set of
/// recently-seen photos in memory.
class LazyContactAvatar extends StatefulWidget {
  /// Device-contact id. Empty → initials only (no fetch).
  final String contactId;
  final String name;
  final double size;

  const LazyContactAvatar({
    super.key,
    required this.contactId,
    required this.name,
    this.size = 48,
  });

  /// Max distinct contact photos kept resident. Beyond this the
  /// least-recently-inserted entry is evicted. Each thumbnail is a few KB, so
  /// this caps avatar memory at a few hundred KB regardless of address-book size.
  static const int _maxCached = 200;

  /// Insertion-ordered cache. Value `null` is a *negative* cache entry
  /// (contact has no photo) so we never re-fetch it.
  static final Map<String, Uint8List?> _cache = <String, Uint8List?>{};

  /// Ids whose fetch is in flight, so concurrent rows don't duplicate the read.
  static final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};

  static final ContactRepository _repo = ContactRepository();

  /// Bumped by [invalidateCache]. Every mounted avatar listens and re-reads.
  ///
  /// Clearing the caches alone was not enough and that is the whole of "the
  /// photo only changes after leaving the contacts screen": an avatar that has
  /// already loaded keeps its bytes in its own State, so the widget on screen
  /// went on rendering the *old* photo until something rebuilt it from scratch.
  static final ValueNotifier<int> generation = ValueNotifier<int>(0);

  /// Clears both caches (call after the address book changes, e.g. a contact
  /// edit) so stale/removed photos don't linger.
  static void invalidateCache() {
    _cache.clear();
    _inFlight.clear();
    generation.value++;
  }

  static Future<Uint8List?> _fetch(String id) {
    if (_cache.containsKey(id)) return Future.value(_cache[id]);
    final existing = _inFlight[id];
    if (existing != null) return existing;

    final future = _repo.getContactThumbnail(id).then((bytes) {
      _cache[id] = bytes;
      if (_cache.length > _maxCached) {
        _cache.remove(_cache.keys.first); // evict least-recently-inserted
      }
      _inFlight.remove(id);
      return bytes;
    });
    _inFlight[id] = future;
    return future;
  }

  @override
  State<LazyContactAvatar> createState() => _LazyContactAvatarState();
}

class _LazyContactAvatarState extends State<LazyContactAvatar> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    LazyContactAvatar.generation.addListener(_onInvalidated);
    _load();
  }

  @override
  void dispose() {
    LazyContactAvatar.generation.removeListener(_onInvalidated);
    super.dispose();
  }

  void _onInvalidated() {
    if (!mounted) return;
    setState(() => _bytes = null);
    _load();
  }

  @override
  void didUpdateWidget(LazyContactAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contactId != widget.contactId) {
      _bytes = null;
      _load();
    }
  }

  void _load() {
    final id = widget.contactId;
    if (id.isEmpty) return;
    // Synchronous hit (already cached, positive or negative) → no rebuild.
    if (LazyContactAvatar._cache.containsKey(id)) {
      _bytes = LazyContactAvatar._cache[id];
      return;
    }
    LazyContactAvatar._fetch(id).then((bytes) {
      if (!mounted || widget.contactId != id || bytes == null) return;
      setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return CircleAvatar(
        radius: widget.size / 2,
        backgroundImage: MemoryImage(_bytes!),
      );
    }
    return AvatarWidget(name: widget.name, size: widget.size);
  }
}
