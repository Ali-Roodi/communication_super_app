import 'package:communication_super_app/features/messages/screens/widgets/linkified_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The runs [LinkifiedText] would underline in [text].
List<String> linksIn(String text) {
  final spans = <String>[];
  LinkifiedText.buildSpan(
    text,
    base: const TextStyle(),
    recognizerFor: (link) {
      spans.add(link);
      return null;
    },
  );
  return spans;
}

void main() {
  group('short links', () {
    test('a scheme-less shortener is a link', () {
      expect(linksIn('لینک: b2n.ir/xK9d3'), ['b2n.ir/xK9d3']);
      expect(linksIn('bit.ly/3aZqP'), ['bit.ly/3aZqP']);
      expect(linksIn('کد تخفیف در yun.ir/ab12 موجود است'), ['yun.ir/ab12']);
      expect(linksIn('tinyurl.com/abcd'), ['tinyurl.com/abcd']);
    });

    test('a bare domain on a known TLD needs no path', () {
      expect(linksIn('از digikala.com بخرید'), ['digikala.com']);
      expect(linksIn('سایت: irancell.ir'), ['irancell.ir']);
    });

    test('an unknown TLD needs a path', () {
      expect(linksIn('foo.bar/baz'), ['foo.bar/baz']);
      expect(linksIn('report.pdf'), isEmpty);
      expect(linksIn('photo.jpeg'), isEmpty);
    });

    test('a full URL still wins as one run', () {
      expect(linksIn('https://b2n.ir/xK9d3'), ['https://b2n.ir/xK9d3']);
      expect(linksIn('www.google.com/search'), ['www.google.com/search']);
    });

    test('prose, amounts and emails are left alone', () {
      expect(linksIn('مبلغ ۱٬۵۰۰٬۰۰۰ ریال'), isEmpty);
      expect(linksIn('مبلغ 1.500.000 ریال'), isEmpty);
      expect(linksIn('نسخه 1.2.3 منتشر شد'), isEmpty);
      expect(linksIn('ali@example.com'), isEmpty);
      expect(linksIn('مبلغ.نهایی را بپردازید'), isEmpty);
    });

    test("the app's own «موقعیت» coordinates are not a link", () {
      // LocationService inserts «35.762397, 51.403567» (ASCII digits, leading
      // LRM) into the composer. A digits-and-dots run must never linkify: the
      // TLD half of the pattern is alphabetic for exactly this reason.
      expect(linksIn('‎35.762397, 51.403567'), isEmpty);
      expect(linksIn('192.168.1.1'), isEmpty);
    });

    test('a hyphen is part of a hostname, a slash and an @ are not', () {
      // Hyphens are legal inside a label, so these really are hostnames.
      expect(linksIn('a-digikala.com'), ['a-digikala.com']);
      expect(linksIn('xdigikala.com'), ['xdigikala.com']);
      // …but the lookbehind must keep the tail of a path or an address from
      // being re-matched as a bare domain of its own.
      expect(linksIn('foo/bar.ir'), isEmpty);
      expect(linksIn('ali@b2n.ir'), isEmpty);
      expect(linksIn('https://x.ir/a/bar.ir'), ['https://x.ir/a/bar.ir']);
    });

    test('a trailing sentence dot is not part of the link', () {
      expect(linksIn('به digikala.com بروید.'), ['digikala.com']);
    });

    test('a USSD code is still a code, not a domain', () {
      expect(linksIn('*140*11#'), ['*140*11#']);
    });
  });

  group('opening', () {
    test('isWebLink covers all three written forms', () {
      expect(LinkifiedText.isWebLink('https://a.ir/b'), isTrue);
      expect(LinkifiedText.isWebLink('www.a.ir'), isTrue);
      expect(LinkifiedText.isWebLink('b2n.ir/xK9d3'), isTrue);
      expect(LinkifiedText.isWebLink('09121234567'), isFalse);
      expect(LinkifiedText.isWebLink('*140#'), isFalse);
    });

    test('a bare domain gets the scheme the sender left off', () {
      expect(
        LinkifiedText.webUriOf('b2n.ir/xK9d3').toString(),
        'https://b2n.ir/xK9d3',
      );
      expect(
        LinkifiedText.webUriOf('http://a.ir').toString(),
        'http://a.ir',
      );
    });
  });
}
