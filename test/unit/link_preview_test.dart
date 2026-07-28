import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/services/link_preview_service.dart';

void main() {
  group('LinkPreviewService.decodeHtmlEntities', () {
    test('decodes decimal entities that used to leak into the card', () {
      // Real title from an MCI SMS link — «&#8211;» was rendered literally.
      expect(
        LinkPreviewService.decodeHtmlEntities(
          'همراه من &#8211; اپلیکیشن رسمی همراه اول',
        ),
        'همراه من – اپلیکیشن رسمی همراه اول',
      );
    });

    test('decodes hex entities and named ones', () {
      expect(
        LinkPreviewService.decodeHtmlEntities('a &#x26; b &nbsp;&mdash; c'),
        'a & b  — c',
      );
    });

    test('decodes double-encoded values', () {
      expect(
        LinkPreviewService.decodeHtmlEntities('نام &amp;#8211; شرکت'),
        'نام – شرکت',
      );
    });

    test('leaves an out-of-range code point alone instead of throwing', () {
      expect(
        LinkPreviewService.decodeHtmlEntities('x &#99999999; y'),
        'x &#99999999; y',
      );
    });
  });

  group('LinkPreviewData', () {
    test('domain strips the www prefix', () {
      const data = LinkPreviewData(url: 'https://www.mci.ir/invoice');
      expect(data.domain, 'mci.ir');
    });

    test('is empty when the page yielded no metadata', () {
      const data = LinkPreviewData(url: 'https://mci.ir');
      expect(data.isEmpty, isTrue);
    });
  });
}
