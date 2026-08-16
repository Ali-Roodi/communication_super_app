import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Open-Graph metadata scraped from a linked page — drives the preview card
/// under a message bubble.
class LinkPreviewData {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;

  /// Site icon (apple-touch-icon / favicon). Used as the card's leading badge
  /// when the page has no `og:image` — a text-only card otherwise reads as a
  /// grey slab.
  final String? iconUrl;

  const LinkPreviewData({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.iconUrl,
  });

  bool get isEmpty => title == null && description == null && imageUrl == null;

  String get domain {
    try {
      return Uri.parse(url).host.replaceFirst('www.', '');
    } catch (_) {
      return url;
    }
  }
}

/// Fetches and caches link previews (og:title / og:description / og:image,
/// falling back to `<title>`). Uses dart:io directly — no extra dependency.
///
/// - One in-flight/completed Future per URL for the session (dedup + cache).
/// - Reads at most [_maxBytes] of the response and gives up after
///   [_timeout]; a failed fetch resolves to null (bubble shows no card).
class LinkPreviewService {
  LinkPreviewService._();
  static final LinkPreviewService instance = LinkPreviewService._();

  static const _timeout = Duration(seconds: 6);
  static const _maxBytes = 128 * 1024;

  final Map<String, Future<LinkPreviewData?>> _cache = {};

  Future<LinkPreviewData?> fetch(String rawUrl) {
    final url = rawUrl.startsWith('http') ? rawUrl : 'https://$rawUrl';
    return _cache.putIfAbsent(url, () async {
      final data = await _fetch(url);
      // Don't cache a miss for the whole session: previews fail on a dropped
      // connection as easily as on a page with no metadata, and the next visit
      // to the chat should try again.
      if (data == null) _cache.remove(url);
      return data;
    });
  }

  Future<LinkPreviewData?> _fetch(String url) async {
    HttpClient? client;
    try {
      final uri = Uri.parse(url);
      if (!uri.hasScheme || uri.host.isEmpty) return null;

      client = HttpClient()
        ..connectionTimeout = _timeout
        // A real browser UA. Link shorteners (zbl.io and friends) bounce a
        // bot-looking agent around until the redirect limit trips, which is
        // why those messages never got a card.
        ..userAgent =
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, '
            'like Gecko) Chrome/120.0 Mobile Safari/537.36';
      final request = await client.getUrl(uri).timeout(_timeout);
      request.followRedirects = true;
      // Shortener → campaign URL → login → app page is already four.
      request.maxRedirects = 10;
      request.headers.set(HttpHeaders.acceptHeader, 'text/html,*/*');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        debugPrint('LinkPreview: $url → HTTP ${response.statusCode}');
        return null;
      }
      final contentType = response.headers.contentType?.mimeType ?? '';
      if (contentType.isNotEmpty && !contentType.contains('html')) return null;

      // Read the head of the document only — og: tags live in <head>.
      final bytes = <int>[];
      await for (final chunk in response.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length >= _maxBytes) break;
      }
      final html = utf8.decode(bytes, allowMalformed: true);

      final title =
          _metaContent(html, 'og:title') ??
          _metaContent(html, 'twitter:title') ??
          _htmlTitle(html);
      final description =
          _metaContent(html, 'og:description') ??
          _metaContent(html, 'twitter:description') ??
          _metaContent(html, 'description');
      // Sites that skip og:image often still carry one of the others; without
      // these fallbacks the card degrades to a bare title + domain line.
      var image =
          _metaContent(html, 'og:image') ??
          _metaContent(html, 'og:image:url') ??
          _metaContent(html, 'twitter:image') ??
          _linkHref(html, 'image_src');
      if (image != null && !image.startsWith('http')) {
        // Resolve protocol-relative and path-relative image URLs.
        image = uri.resolve(image).toString();
      }
      var icon = _linkHref(html, 'apple-touch-icon') ?? _linkHref(html, 'icon');
      if (icon != null && !icon.startsWith('http')) {
        icon = uri.resolve(icon).toString();
      }

      final data = LinkPreviewData(
        url: url,
        title: title,
        description: description,
        imageUrl: image,
        iconUrl: icon,
      );
      if (data.isEmpty) debugPrint('LinkPreview: $url → no metadata');
      return data.isEmpty ? null : data;
    } catch (e) {
      debugPrint('LinkPreview: $url → $e');
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// `<meta property="og:x" content="...">` — attribute order and quote style
  /// vary per site, so both orders are tried, for property= and name= alike.
  String? _metaContent(String html, String key) {
    final k = RegExp.escape(key);
    final patterns = [
      RegExp(
        '<meta[^>]*(?:property|name)=["\']$k["\'][^>]*content=["\']([^"\']*)["\']',
        caseSensitive: false,
      ),
      RegExp(
        '<meta[^>]*content=["\']([^"\']*)["\'][^>]*(?:property|name)=["\']$k["\']',
        caseSensitive: false,
      ),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(html);
      final value = m?.group(1)?.trim();
      if (value != null && value.isNotEmpty) return _decodeEntities(value);
    }
    return null;
  }

  String? _htmlTitle(String html) {
    final m = RegExp(
      r'<title[^>]*>([^<]+)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    final value = m?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : _decodeEntities(value);
  }

  /// `<link rel="…" href="…">` — the icon / image_src fallbacks.
  String? _linkHref(String html, String rel) {
    final r = RegExp.escape(rel);
    final patterns = [
      RegExp(
        '<link[^>]*rel=["\'][^"\']*$r[^"\']*["\'][^>]*href=["\']([^"\']*)["\']',
        caseSensitive: false,
      ),
      RegExp(
        '<link[^>]*href=["\']([^"\']*)["\'][^>]*rel=["\'][^"\']*$r[^"\']*["\']',
        caseSensitive: false,
      ),
    ];
    for (final p in patterns) {
      final value = p.firstMatch(html)?.group(1)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// Named **and numeric** entities. The numeric ones matter: titles routinely
  /// carry `&#8211;` (–) and it used to be rendered literally in the card. The
  /// pass runs twice because double-encoded values (`&amp;#8211;`) are common.
  static String decodeHtmlEntities(String s) => _decodeOnce(_decodeOnce(s));

  String _decodeEntities(String s) => decodeHtmlEntities(s);

  static const _namedEntities = {
    '&amp;': '&',
    '&quot;': '"',
    '&apos;': "'",
    '&lt;': '<',
    '&gt;': '>',
    '&nbsp;': ' ',
    '&ndash;': '–',
    '&mdash;': '—',
    '&hellip;': '…',
    '&laquo;': '«',
    '&raquo;': '»',
    '&zwnj;': '‌',
  };

  static final _numericEntity = RegExp(r'&#(x?)([0-9a-fA-F]+);');

  static String _decodeOnce(String s) {
    var out = s;
    for (final entry in _namedEntities.entries) {
      out = out.replaceAll(entry.key, entry.value);
    }
    return out.replaceAllMapped(_numericEntity, (m) {
      final code = int.tryParse(
        m.group(2)!,
        radix: m.group(1)!.isEmpty ? 10 : 16,
      );
      // Out-of-range code points would throw — leave those untouched.
      if (code == null || code < 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    });
  }
}
