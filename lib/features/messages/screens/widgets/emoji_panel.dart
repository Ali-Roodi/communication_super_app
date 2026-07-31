import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The emoji keyboard Google Messages shows under the composer: a category
/// strip, one continuous scroll through every category with inline headings,
/// a «اخیر» section fed by what the user actually picks, skin-tone variants on
/// long-press, and a backspace that deletes into the message like the system
/// keyboard's does.
///
/// This replaced a flat 130-emoji grid with no categories, no recents and no
/// backspace — the panel opened onto smileys and there was no way to reach a
/// flag or a vehicle from it at all.
class EmojiPanel extends StatefulWidget {
  const EmojiPanel({
    super.key,
    required this.onSelected,
    required this.onBackspace,
    this.height = 280,
  });

  /// Called with the emoji to insert at the cursor.
  final ValueChanged<String> onSelected;

  /// Deletes one character before the cursor — the panel replaces the system
  /// keyboard while it is open, so it has to carry its own backspace.
  final VoidCallback onBackspace;

  final double height;

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> {
  static const String _recentsKey = 'emoji_recents_v1';
  static const int _maxRecents = 32;

  /// Recently picked emoji, newest first. Loaded once and kept in memory so
  /// re-opening the panel inside a session never waits on disk.
  static List<String>? _recents;

  final ScrollController _controller = ScrollController();

  /// Per-category scroll offsets, recomputed whenever the layout changes.
  List<double> _offsets = const [];

  /// Which tab is lit. A notifier, not `setState`: this changes continuously
  /// while the user scrolls, and rebuilding the panel (and with it every grid
  /// sliver) on each category boundary is jank for a ten-icon strip.
  final ValueNotifier<int> _active = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncActiveTab);
    if (_recents == null) _loadRecents();
  }

  @override
  void dispose() {
    _controller.removeListener(_syncActiveTab);
    _controller.dispose();
    _active.dispose();
    super.dispose();
  }

  Future<void> _loadRecents() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _recents = prefs.getStringList(_recentsKey) ?? <String>[];
    } catch (_) {
      _recents = <String>[];
    }
    if (mounted) setState(() {});
  }

  Future<void> _remember(String emoji) async {
    final list = List<String>.of(_recents ?? const [])
      ..remove(emoji)
      ..insert(0, emoji);
    if (list.length > _maxRecents) list.removeRange(_maxRecents, list.length);
    _recents = list;
    // Not awaited by the caller: the emoji must land in the field on the tap,
    // never one disk write later.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentsKey, list);
    } catch (_) {
      // A failed write only costs the recents ordering next launch.
    }
  }

  void _pick(String emoji) {
    HapticFeedback.selectionClick();
    widget.onSelected(emoji);
    _remember(emoji);
    // The recents row itself is only re-sorted on the next open, so the grid
    // does not reshuffle under the finger mid-pick.
  }

  /// Categories actually rendered — «اخیر» is dropped while it is empty, the
  /// way Google Messages hides it on a fresh install.
  List<EmojiCategory> get _categories {
    final recents = _recents ?? const <String>[];
    return [
      if (recents.isNotEmpty)
        EmojiCategory('اخیر', Icons.history, List<String>.of(recents)),
      ...emojiCategories,
    ];
  }

  void _syncActiveTab() {
    if (_offsets.isEmpty || !_controller.hasClients) return;
    final offset = _controller.offset;
    var index = 0;
    for (var i = 0; i < _offsets.length; i++) {
      if (_offsets[i] <= offset + 1) index = i;
    }
    _active.value = index;
  }

  void _jumpTo(int index) {
    if (index >= _offsets.length || !_controller.hasClients) return;
    _active.value = index;
    _controller.animateTo(
      _offsets[index].clamp(0.0, _controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categories = _categories;

    return Container(
      height: widget.height,
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ValueListenableBuilder<int>(
            valueListenable: _active,
            builder: (context, active, _) => _CategoryStrip(
              categories: categories,
              active: active,
              onSelect: _jumpTo,
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // ~40 logical px per emoji, so the column count follows the
                // screen instead of being fixed at 6 on every device.
                final columns = (constraints.maxWidth / 44)
                    .floor()
                    .clamp(6, 10);
                final tile = constraints.maxWidth / columns;

                final offsets = <double>[];
                final slivers = <Widget>[];
                var running = 0.0;
                for (final category in categories) {
                  offsets.add(running);
                  running += _kHeaderHeight;
                  running += (category.emojis.length / columns).ceil() * tile;
                  slivers
                    ..add(
                      SliverToBoxAdapter(
                        child: _CategoryHeader(title: category.title),
                      ),
                    )
                    ..add(
                      SliverGrid(
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                            ),
                        delegate: SliverChildBuilderDelegate(
                          (_, i) => _EmojiCell(
                            emoji: category.emojis[i],
                            onTap: _pick,
                          ),
                          childCount: category.emojis.length,
                        ),
                      ),
                    );
                }
                _offsets = offsets;

                return CustomScrollView(
                  controller: _controller,
                  slivers: [
                    ...slivers,
                    const SliverToBoxAdapter(child: SizedBox(height: 48)),
                  ],
                );
              },
            ),
          ),
          _PanelFooter(onBackspace: widget.onBackspace),
        ],
      ),
    );
  }
}

const double _kHeaderHeight = 30;

// ── Category strip ───────────────────────────────────────────────────────────

class _CategoryStrip extends StatelessWidget {
  const _CategoryStrip({
    required this.categories,
    required this.active,
    required this.onSelect,
  });

  final List<EmojiCategory> categories;
  final int active;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: categories.length,
        itemBuilder: (_, i) {
          final selected = i == active;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            child: Material(
              color: selected ? scheme.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onSelect(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(
                    categories[i].icon,
                    size: 20,
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: _kHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Cell ─────────────────────────────────────────────────────────────────────

/// One emoji. Long-pressing a tone-capable emoji opens the skin-tone row —
/// Google Messages' behaviour, and the only way those variants are reachable.
class _EmojiCell extends StatelessWidget {
  const _EmojiCell({required this.emoji, required this.onTap});

  final String emoji;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final tones = skinToneVariants(emoji);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onTap(emoji),
      onLongPress: tones.isEmpty
          ? null
          : () {
              HapticFeedback.mediumImpact();
              _showTonePicker(context, tones);
            },
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 26))),
    );
  }

  Future<void> _showTonePicker(
    BuildContext context,
    List<String> tones,
  ) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;

    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        topLeft.dy - 52,
        overlay.size.width - topLeft.dx - box.size.width,
        0,
      ),
      constraints: const BoxConstraints(),
      items: [
        PopupMenuItem<String>(
          padding: EdgeInsets.zero,
          enabled: false,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final tone in tones)
                InkWell(
                  onTap: () => Navigator.of(context).pop(tone),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                    child: Text(
                      tone,
                      style: const TextStyle(fontSize: 26),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    if (picked != null) onTap(picked);
  }
}

// ── Footer ───────────────────────────────────────────────────────────────────

class _PanelFooter extends StatelessWidget {
  const _PanelFooter({required this.onBackspace});

  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.backspace_outlined, size: 20),
            color: scheme.onSurfaceVariant,
            tooltip: 'حذف',
            onPressed: onBackspace,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

// ── Skin tones ───────────────────────────────────────────────────────────────

const List<int> _kToneModifiers = [
  0x1F3FB,
  0x1F3FC,
  0x1F3FD,
  0x1F3FE,
  0x1F3FF,
];

/// Code-point ranges whose emoji accept a Fitzpatrick modifier.
const List<List<int>> _kToneCapable = [
  [0x261D, 0x261D],
  [0x26F9, 0x26F9],
  [0x270A, 0x270D],
  [0x1F385, 0x1F385],
  [0x1F3C2, 0x1F3C4],
  [0x1F3C7, 0x1F3C7],
  [0x1F3CA, 0x1F3CC],
  [0x1F442, 0x1F443],
  [0x1F446, 0x1F450],
  [0x1F466, 0x1F478],
  [0x1F47C, 0x1F47C],
  [0x1F481, 0x1F483],
  [0x1F485, 0x1F487],
  [0x1F48F, 0x1F48F],
  [0x1F491, 0x1F491],
  [0x1F4AA, 0x1F4AA],
  [0x1F574, 0x1F575],
  [0x1F57A, 0x1F57A],
  [0x1F590, 0x1F590],
  [0x1F595, 0x1F596],
  [0x1F645, 0x1F647],
  [0x1F64B, 0x1F64F],
  [0x1F6A3, 0x1F6A3],
  [0x1F6B4, 0x1F6B6],
  [0x1F6C0, 0x1F6C0],
  [0x1F6CC, 0x1F6CC],
  [0x1F90C, 0x1F90C],
  [0x1F90F, 0x1F90F],
  [0x1F918, 0x1F91F],
  [0x1F926, 0x1F926],
  [0x1F930, 0x1F939],
  [0x1F93D, 0x1F93E],
  [0x1F977, 0x1F977],
  [0x1F9B5, 0x1F9B6],
  [0x1F9BB, 0x1F9BB],
  [0x1F9CD, 0x1F9CF],
  [0x1F9D1, 0x1F9DD],
  [0x1FAC3, 0x1FAC5],
  [0x1FAF0, 0x1FAF8],
];

/// The five toned forms of [emoji], or an empty list when it takes no tone.
///
/// The modifier goes straight after the base code point, *replacing* a
/// variation selector if one follows it (✌️ is `270C FE0F`; its medium tone is
/// `270C 1F3FD`, not `270C FE0F 1F3FD`, which renders as a stray colour swatch).
List<String> skinToneVariants(String emoji) {
  final runes = emoji.runes.toList();
  if (runes.isEmpty) return const [];
  final base = runes.first;
  final capable = _kToneCapable.any((r) => base >= r[0] && base <= r[1]);
  if (!capable) return const [];
  // Already toned, or a multi-person sequence — leave it alone.
  if (runes.any((r) => _kToneModifiers.contains(r))) return const [];

  final tail = runes.sublist(1).where((r) => r != 0xFE0F).toList();
  return [
    for (final modifier in _kToneModifiers)
      String.fromCharCodes([base, modifier, ...tail]),
  ];
}

// ── Data ─────────────────────────────────────────────────────────────────────

class EmojiCategory {
  const EmojiCategory(this.title, this.icon, this.emojis);

  final String title;
  final IconData icon;
  final List<String> emojis;
}

/// The picker's contents, in Google Messages' category order.
const List<EmojiCategory> emojiCategories = [
  EmojiCategory('لبخند و احساسات', Icons.emoji_emotions_outlined, [
    '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '🫠', '😉',
    '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😙', '🥲', '😋', '😛',
    '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🫢', '🫣', '🤫', '🤔', '🫡', '🤐',
    '🤨', '😐', '😑', '😶', '🫥', '😶‍🌫️', '😏', '😒', '🙄', '😬', '😮‍💨',
    '🤥', '🫨', '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮',
    '🤧', '🥵', '🥶', '🥴', '😵', '😵‍💫', '🤯', '🤠', '🥳', '🥸', '😎', '🤓',
    '🧐', '😕', '🫤', '😟', '🙁', '☹️', '😮', '😯', '😲', '😳', '🥺', '🥹',
    '😦', '😧', '😨', '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞', '😓',
    '😩', '😫', '🥱', '😤', '😡', '😠', '🤬', '😈', '👿', '💀', '☠️', '💩',
    '🤡', '👹', '👺', '👻', '👽', '👾', '🤖', '😺', '😸', '😹', '😻', '😼',
    '😽', '🙀', '😿', '😾', '🙈', '🙉', '🙊', '💋', '💌', '💘', '💝', '💖',
    '💗', '💓', '💞', '💕', '💟', '❣️', '💔', '❤️‍🔥', '❤️‍🩹', '❤️', '🩷',
    '🧡', '💛', '💚', '💙', '🩵', '💜', '🤎', '🖤', '🩶', '🤍', '💯', '💢',
    '💥', '💫', '💦', '💨', '🕳️', '💬', '👁️‍🗨️', '🗨️', '🗯️', '💭', '💤',
  ]),
  EmojiCategory('افراد و بدن', Icons.emoji_people_outlined, [
    '👋', '🤚', '🖐️', '✋', '🖖', '🫱', '🫲', '🫳', '🫴', '🫷', '🫸', '👌',
    '🤌', '🤏', '✌️', '🤞', '🫰', '🤟', '🤘', '🤙', '👈', '👉', '👆', '🖕',
    '👇', '☝️', '🫵', '👍', '👎', '✊', '👊', '🤛', '🤜', '👏', '🙌', '🫶',
    '👐', '🤲', '🤝', '🙏', '✍️', '💅', '🤳', '💪', '🦾', '🦿', '🦵', '🦶',
    '👂', '🦻', '👃', '🧠', '🫀', '🫁', '🦷', '🦴', '👀', '👁️', '👅', '👄',
    '🫦', '👶', '🧒', '👦', '👧', '🧑', '👱', '👨', '🧔', '👩', '🧓', '👴',
    '👵', '🙍', '🙎', '🙅', '🙆', '💁', '🙋', '🧏', '🙇', '🤦', '🤷', '👮',
    '🕵️', '💂', '🥷', '👷', '🫅', '🤴', '👸', '👳', '👲', '🧕', '🤵', '👰',
    '🤰', '🫃', '🫄', '🤱', '👼', '🎅', '🤶', '🦸', '🦹', '🧙', '🧚', '🧛',
    '🧜', '🧝', '🧞', '🧟', '🧌', '💆', '💇', '🚶', '🧍', '🧎', '🏃', '💃',
    '🕺', '🕴️', '👯', '🧖', '🧗', '🤺', '🏇', '⛷️', '🏂', '🏌️', '🏄', '🚣',
    '🏊', '⛹️', '🏋️', '🚴', '🚵', '🤸', '🤼', '🤽', '🤾', '🤹', '🧘', '🛀',
    '🛌', '👭', '👫', '👬', '💏', '💑', '👪', '🗣️', '👤', '👥', '🫂', '👣',
  ]),
  EmojiCategory('حیوانات و طبیعت', Icons.pets_outlined, [
    '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐻‍❄️', '🐨', '🐯', '🦁',
    '🐮', '🐷', '🐽', '🐸', '🐵', '🙈', '🙉', '🙊', '🐒', '🐔', '🐧', '🐦',
    '🐤', '🐣', '🐥', '🦆', '🦅', '🦉', '🦇', '🐺', '🐗', '🐴', '🦄', '🐝',
    '🪱', '🐛', '🦋', '🐌', '🐞', '🐜', '🪰', '🪲', '🪳', '🦟', '🦗', '🕷️',
    '🕸️', '🦂', '🐢', '🐍', '🦎', '🦖', '🦕', '🐙', '🦑', '🦐', '🦞', '🦀',
    '🐡', '🐠', '🐟', '🐬', '🐳', '🐋', '🦈', '🦭', '🐊', '🐅', '🐆', '🦓',
    '🦍', '🦧', '🦣', '🐘', '🦛', '🦏', '🐪', '🐫', '🦒', '🦘', '🦬', '🐃',
    '🐂', '🐄', '🐎', '🐖', '🐏', '🐑', '🦙', '🐐', '🦌', '🐕', '🐩', '🦮',
    '🐈', '🐈‍⬛', '🪶', '🐓', '🦃', '🦤', '🦚', '🦜', '🦢', '🦩', '🕊️', '🐇',
    '🦝', '🦨', '🦡', '🦫', '🦦', '🦥', '🐁', '🐀', '🐿️', '🦔', '🐾', '🐉',
    '🐲', '🌵', '🎄', '🌲', '🌳', '🌴', '🪵', '🌱', '🌿', '☘️', '🍀', '🎍',
    '🪴', '🎋', '🍃', '🍂', '🍁', '🍄', '🐚', '🪸', '🪨', '🌾', '💐', '🌷',
    '🌹', '🥀', '🌺', '🌸', '🌼', '🌻', '🌞', '🌝', '🌛', '🌜', '🌚', '🌕',
    '🌖', '🌗', '🌘', '🌑', '🌒', '🌓', '🌔', '🌙', '🌎', '🌍', '🌏', '🪐',
    '💫', '⭐', '🌟', '✨', '⚡', '☄️', '💥', '🔥', '🌪️', '🌈', '☀️', '🌤️',
    '⛅', '🌥️', '☁️', '🌦️', '🌧️', '⛈️', '🌩️', '🌨️', '❄️', '☃️', '⛄',
    '🌬️', '💨', '💧', '💦', '🫧', '☔', '☂️', '🌊', '🌫️',
  ]),
  EmojiCategory('خوراک و نوشیدنی', Icons.restaurant_outlined, [
    '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍈', '🍒',
    '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑', '🥦', '🥬', '🥒', '🌶️',
    '🫑', '🌽', '🥕', '🫒', '🧄', '🧅', '🥔', '🍠', '🫘', '🥐', '🥯', '🍞',
    '🥖', '🥨', '🧀', '🥚', '🍳', '🧈', '🥞', '🧇', '🥓', '🥩', '🍗', '🍖',
    '🦴', '🌭', '🍔', '🍟', '🍕', '🫓', '🥪', '🥙', '🧆', '🌮', '🌯', '🫔',
    '🥗', '🥘', '🫕', '🥫', '🍝', '🍜', '🍲', '🍛', '🍣', '🍱', '🥟', '🦪',
    '🍤', '🍙', '🍚', '🍘', '🍥', '🥠', '🥮', '🍢', '🍡', '🍧', '🍨', '🍦',
    '🥧', '🧁', '🍰', '🎂', '🍮', '🍭', '🍬', '🍫', '🍿', '🍩', '🍪', '🌰',
    '🥜', '🍯', '🥛', '🍼', '🫖', '☕', '🍵', '🧃', '🥤', '🧋', '🍶', '🍺',
    '🍻', '🥂', '🍷', '🥃', '🍸', '🍹', '🧉', '🍾', '🧊', '🥄', '🍴', '🍽️',
    '🥣', '🥡', '🥢', '🧂',
  ]),
  EmojiCategory('فعالیت و ورزش', Icons.sports_soccer_outlined, [
    '⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉', '🥏', '🎱', '🪀', '🏓',
    '🏸', '🏒', '🏑', '🥍', '🏏', '🪃', '🥅', '⛳', '🪁', '🏹', '🎣', '🤿',
    '🥊', '🥋', '🎽', '🛹', '🛼', '🛷', '⛸️', '🥌', '🎿', '⛷️', '🏂', '🪂',
    '🏋️', '🤼', '🤸', '⛹️', '🤺', '🤾', '🏌️', '🏇', '🧘', '🏄', '🏊', '🤽',
    '🚣', '🧗', '🚵', '🚴', '🏆', '🥇', '🥈', '🥉', '🏅', '🎖️', '🏵️', '🎗️',
    '🎫', '🎟️', '🎪', '🤹', '🎭', '🩰', '🎨', '🎬', '🎤', '🎧', '🎼', '🎹',
    '🥁', '🪘', '🎷', '🎺', '🪗', '🎸', '🪕', '🎻', '🎲', '♟️', '🎯', '🎳',
    '🎮', '🎰', '🧩',
  ]),
  EmojiCategory('سفر و مکان', Icons.directions_car_outlined, [
    '🚗', '🚕', '🚙', '🚌', '🚎', '🏎️', '🚓', '🚑', '🚒', '🚐', '🛻', '🚚',
    '🚛', '🚜', '🦯', '🦽', '🦼', '🛴', '🚲', '🛵', '🏍️', '🛺', '🚨', '🚔',
    '🚍', '🚘', '🚖', '🚡', '🚠', '🚟', '🚃', '🚋', '🚞', '🚝', '🚄', '🚅',
    '🚈', '🚂', '🚆', '🚇', '🚊', '🚉', '✈️', '🛫', '🛬', '🛩️', '💺', '🛰️',
    '🚀', '🛸', '🚁', '🛶', '⛵', '🚤', '🛥️', '🛳️', '⛴️', '🚢', '⚓', '🪝',
    '⛽', '🚧', '🚦', '🚥', '🗺️', '🗿', '🗽', '🗼', '🏰', '🏯', '🏟️', '🎡',
    '🎢', '🎠', '⛲', '⛱️', '🏖️', '🏝️', '🏜️', '🌋', '⛰️', '🏔️', '🗻', '🏕️',
    '⛺', '🛖', '🏠', '🏡', '🏘️', '🏚️', '🏗️', '🏭', '🏢', '🏬', '🏣', '🏤',
    '🏥', '🏦', '🏨', '🏪', '🏫', '🏩', '💒', '🏛️', '⛪', '🕌', '🕍', '🛕',
    '🕋', '⛩️', '🛤️', '🛣️', '🗾', '🎑', '🏞️', '🌅', '🌄', '🌠', '🎇', '🎆',
    '🌇', '🌆', '🏙️', '🌃', '🌌', '🌉', '🌁',
  ]),
  EmojiCategory('اشیا', Icons.lightbulb_outline, [
    '⌚', '📱', '📲', '💻', '⌨️', '🖥️', '🖨️', '🖱️', '🖲️', '🕹️', '🗜️', '💽',
    '💾', '💿', '📀', '📼', '📷', '📸', '📹', '🎥', '📽️', '🎞️', '📞', '☎️',
    '📟', '📠', '📺', '📻', '🎙️', '🎚️', '🎛️', '🧭', '⏱️', '⏲️', '⏰', '🕰️',
    '⌛', '⏳', '📡', '🔋', '🪫', '🔌', '💡', '🔦', '🕯️', '🪔', '🧯', '🛢️',
    '💸', '💵', '💴', '💶', '💷', '🪙', '💰', '💳', '🧾', '💎', '⚖️', '🪜',
    '🧰', '🪛', '🔧', '🔨', '⚒️', '🛠️', '⛏️', '🪚', '🔩', '⚙️', '🪤', '🧱',
    '⛓️', '🧲', '🔫', '💣', '🧨', '🪓', '🔪', '🗡️', '⚔️', '🛡️', '🚬', '⚰️',
    '🪦', '⚱️', '🏺', '🔮', '📿', '🧿', '🪬', '💈', '⚗️', '🔭', '🔬', '🕳️',
    '🩻', '🩹', '🩺', '💊', '💉', '🩸', '🧬', '🦠', '🧫', '🧪', '🌡️', '🧹',
    '🪮', '🧺', '🧻', '🚽', '🚰', '🚿', '🛁', '🛀', '🧼', '🪥', '🪒', '🧽',
    '🪣', '🧴', '🛎️', '🔑', '🗝️', '🚪', '🪑', '🛋️', '🛏️', '🛌', '🧸', '🪆',
    '🖼️', '🪞', '🪟', '🛍️', '🛒', '🎁', '🎈', '🎏', '🎀', '🪄', '🪅', '🎊',
    '🎉', '🪩', '🎎', '🏮', '🎐', '🧧', '✉️', '📩', '📨', '📧', '💌', '📥',
    '📤', '📦', '🏷️', '🪧', '📪', '📫', '📬', '📭', '📮', '📯', '📜', '📃',
    '📄', '📑', '📊', '📈', '📉', '🗒️', '🗓️', '📆', '📅', '🗑️', '📇', '🗃️',
    '🗳️', '🗄️', '📋', '📁', '📂', '🗂️', '🗞️', '📰', '📓', '📔', '📒', '📕',
    '📗', '📘', '📙', '📚', '📖', '🔖', '🧷', '🔗', '📎', '🖇️', '📐', '📏',
    '🧮', '📌', '📍', '✂️', '🖊️', '🖋️', '✒️', '🖌️', '🖍️', '📝', '✏️', '🔍',
    '🔎', '🔏', '🔐', '🔒', '🔓',
  ]),
  EmojiCategory('نمادها', Icons.emoji_symbols_outlined, [
    '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', '❣️', '💕',
    '💞', '💓', '💗', '💖', '💘', '💝', '☮️', '✝️', '☪️', '🕉️', '☸️', '✡️',
    '🔯', '🕎', '☯️', '☦️', '🛐', '⛎', '♈', '♉', '♊', '♋', '♌', '♍', '♎',
    '♏', '♐', '♑', '♒', '♓', '🆔', '⚛️', '🉑', '☢️', '☣️', '📴', '📳', '🈶',
    '🈚', '🈸', '🈺', '🈷️', '✴️', '🆚', '💮', '🉐', '㊙️', '㊗️', '🈴', '🈵',
    '🈹', '🈲', '🅰️', '🅱️', '🆎', '🆑', '🅾️', '🆘', '❌', '⭕', '🛑', '⛔',
    '📛', '🚫', '💯', '💢', '♨️', '🚷', '🚯', '🚳', '🚱', '🔞', '📵', '🚭',
    '❗', '❕', '❓', '❔', '‼️', '⁉️', '🔅', '🔆', '〽️', '⚠️', '🚸', '🔱',
    '⚜️', '🔰', '♻️', '✅', '🈯', '💹', '❇️', '✳️', '❎', '🌐', '💠', 'Ⓜ️',
    '🌀', '💤', '🏧', '🚾', '♿', '🅿️', '🛗', '🈳', '🈂️', '🛂', '🛃', '🛄',
    '🛅', '🚹', '🚺', '🚼', '⚧️', '🚻', '🚮', '🎦', '📶', '🈁', '🔣', 'ℹ️',
    '🔤', '🔡', '🔠', '🆖', '🆗', '🆙', '🆒', '🆕', '🆓', '0️⃣', '1️⃣', '2️⃣',
    '3️⃣', '4️⃣', '5️⃣', '6️⃣', '7️⃣', '8️⃣', '9️⃣', '🔟', '🔢', '#️⃣', '*️⃣',
    '⏏️', '▶️', '⏸️', '⏯️', '⏹️', '⏺️', '⏭️', '⏮️', '⏩', '⏪', '⏫', '⏬',
    '◀️', '🔼', '🔽', '➡️', '⬅️', '⬆️', '⬇️', '↗️', '↘️', '↙️', '↖️', '↕️',
    '↔️', '↪️', '↩️', '⤴️', '⤵️', '🔀', '🔁', '🔂', '🔄', '🔃', '🎵', '🎶',
    '➕', '➖', '➗', '✖️', '🟰', '♾️', '💲', '💱', '™️', '©️', '®️', '👁️‍🗨️',
    '🔚', '🔙', '🔛', '🔝', '🔜', '〰️', '➰', '➿', '✔️', '☑️', '🔘', '🔴',
    '🟠', '🟡', '🟢', '🔵', '🟣', '⚫', '⚪', '🟤', '🔺', '🔻', '🔸', '🔹',
    '🔶', '🔷', '🔳', '🔲', '▪️', '▫️', '◾', '◽', '◼️', '◻️', '🟥', '🟧',
    '🟨', '🟩', '🟦', '🟪', '⬛', '⬜', '🟫', '🔈', '🔇', '🔉', '🔊', '🔔',
    '🔕', '📣', '📢', '💬', '💭', '🗯️', '♠️', '♣️', '♥️', '♦️', '🃏', '🎴',
    '🀄', '🕐', '🕑', '🕒', '🕓', '🕔', '🕕', '🕖', '🕗', '🕘', '🕙', '🕚',
    '🕛',
  ]),
  EmojiCategory('پرچم‌ها', Icons.flag_outlined, [
    '🏳️', '🏴', '🏴‍☠️', '🏁', '🚩', '🏳️‍🌈', '🏳️‍⚧️', '🇮🇷', '🇦🇫', '🇦🇪',
    '🇦🇲', '🇦🇹', '🇦🇺', '🇦🇿', '🇧🇭', '🇧🇩', '🇧🇪', '🇧🇷', '🇨🇦', '🇨🇭',
    '🇨🇳', '🇩🇪', '🇩🇰', '🇪🇬', '🇪🇸', '🇫🇮', '🇫🇷', '🇬🇧', '🇬🇪', '🇬🇷',
    '🇭🇺', '🇮🇩', '🇮🇪', '🇮🇱', '🇮🇳', '🇮🇶', '🇮🇸', '🇮🇹', '🇯🇴', '🇯🇵',
    '🇰🇬', '🇰🇷', '🇰🇼', '🇰🇿', '🇱🇧', '🇱🇾', '🇲🇦', '🇲🇾', '🇳🇱', '🇳🇴',
    '🇳🇿', '🇴🇲', '🇵🇰', '🇵🇱', '🇵🇸', '🇵🇹', '🇶🇦', '🇷🇴', '🇷🇸', '🇷🇺',
    '🇸🇦', '🇸🇪', '🇸🇬', '🇸🇾', '🇹🇯', '🇹🇲', '🇹🇳', '🇹🇷', '🇺🇦', '🇺🇸',
    '🇺🇿', '🇾🇪', '🇿🇦',
  ]),
];
