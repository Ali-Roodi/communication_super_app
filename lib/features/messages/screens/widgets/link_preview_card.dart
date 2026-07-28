import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/link_preview_service.dart';

/// Open-Graph preview card rendered under the text of a bubble whose body
/// contains a web link. Collapses to nothing while loading or when the page
/// yields no metadata, so bubbles without previews look exactly as before.
class LinkPreviewCard extends StatefulWidget {
  final String url;

  /// Bubble background is the primary color for sent messages — the card
  /// adapts its overlay/text colors through [onDark].
  final bool onDark;

  const LinkPreviewCard({super.key, required this.url, this.onDark = false});

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  LinkPreviewData? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _data = null;
      _load();
    }
  }

  Future<void> _load() async {
    final data = await LinkPreviewService.instance.fetch(widget.url);
    if (mounted && data != null) setState(() => _data = data);
  }

  Future<void> _open() async {
    final link = widget.url.startsWith('http')
        ? widget.url
        : 'https://${widget.url}';
    try {
      await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) return const SizedBox.shrink();

    final fg = widget.onDark ? Colors.white : Colors.black87;
    final fgSoft = widget.onDark ? Colors.white70 : Colors.black54;
    final overlay = widget.onDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.06);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GestureDetector(
        onTap: _open,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            color: overlay,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (data.imageUrl != null)
                  Image.network(
                    data.imageUrl!,
                    width: double.infinity,
                    height: 140,
                    fit: BoxFit.cover,
                    // Broken/blocked image: keep the text-only card.
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Without a hero image the card was a bare grey slab —
                      // the site icon gives it the same anchor Google Messages
                      // puts on a compact preview.
                      if (data.imageUrl == null && data.iconUrl != null) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(
                            data.iconUrl!,
                            width: 36,
                            height: 36,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (data.title != null)
                              Text(
                                data.title!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: fg,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            if (data.description != null) ...[
                              const SizedBox(height: 3),
                              Text(
                                data.description!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: fgSoft, fontSize: 12),
                              ),
                            ],
                            const SizedBox(height: 3),
                            Text(
                              data.domain,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: fgSoft, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
