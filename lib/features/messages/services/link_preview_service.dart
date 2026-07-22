import 'dart:convert';
import 'dart:io';

/// Open-Graph metadata scraped from a linked page — drives the preview card
/// under a message bubble.
class LinkPreviewData {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;

  const LinkPreviewData({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
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
    return _cache.putIfAbsent(url, () => _fetch(url));
  }

  Future<LinkPreviewData?> _fetch(String url) async {
    HttpClient? client;
    try {
      final uri = Uri.parse(url);
      if (!uri.hasScheme || uri.host.isEmpty) return null;

      client = HttpClient()
        ..connectionTimeout = _timeout
        ..userAgent = 'Mozilla/5.0 (Android) HamresanLinkPreview/1.0';
      final request = await client.getUrl(uri).timeout(_timeout);
      request.followRedirects = true;
      request.maxRedirects = 4;
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) return null;
      final contentType = response.headers.contentType?.mimeType ?? '';
      if (contentType.isNotEmpty && !contentType.contains('html')) return null;

      // Read the head of the document only — og: tags live in <head>.
      final bytes = <int>[];
      await for (final chunk in response.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length >= _maxBytes) break;
      }
      final html = utf8.decode(bytes, allowMalformed: true);

      final title = _metaContent(html, 'og:title') ?? _htmlTitle(html);
      final description =
          _metaContent(html, 'og:description') ??
          _metaContent(html, 'description');
      var image = _metaContent(html, 'og:image');
      if (image != null && !image.startsWith('http')) {
        // Resolve protocol-relative and path-relative image URLs.
        image = uri.resolve(image).toString();
      }

      final data = LinkPreviewData(
        url: url,
        title: title,
        description: description,
        imageUrl: image,
      );
      return data.isEmpty ? null : data;
    } catch (_) {
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

  String _decodeEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');
}
