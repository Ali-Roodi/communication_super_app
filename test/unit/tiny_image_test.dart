import 'dart:typed_data';

import 'package:communication_super_app/features/messages/models/template_wire.dart';
import 'package:communication_super_app/features/messages/models/tiny_image.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pinned. Older builds on the other phone read this; a different picture
/// format is a new version in the sigil, never a new expected value here.
const _goldenChecker = '[#I1:8x2:b]qlU';
const _goldenBlank = '[#I1:16x8:r]8QA';

Uint8List _gray(int width, int height, int Function(int x, int y) value) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final at = (y * width + x) * 4;
      final v = value(x, y);
      rgba[at] = v;
      rgba[at + 1] = v;
      rgba[at + 2] = v;
      rgba[at + 3] = 255;
    }
  }
  return rgba;
}

void main() {
  group('the wire format', () {
    test('a raw picture has the pinned text', () {
      final image = TinyImage.fromBits(8, 2, Uint8List.fromList([0xAA, 0x55]));
      expect(image.wire, _goldenChecker);
    });

    test('a picture that compresses goes out packed', () {
      final image = TinyImage.fromBits(16, 8, Uint8List(16));
      expect(image.wire, _goldenBlank);
    });

    test('the pinned texts read back', () {
      final checker = TinyImage.decode(_goldenChecker)!;
      expect(checker.width, 8);
      expect(checker.height, 2);
      expect(checker.isBlack(0, 0), isTrue);
      expect(checker.isBlack(1, 0), isFalse);
      expect(checker.isBlack(0, 1), isFalse);
      expect(checker.isBlack(1, 1), isTrue);

      final blank = TinyImage.decode(_goldenBlank)!;
      expect(blank.width, 16);
      expect(blank.isBlack(15, 7), isFalse);
    });

    test('every pixel survives the trip, packed or not', () {
      final noisy = Uint8List.fromList(
        List.generate(90, (i) => (i * 73 + 11) & 0xFF),
      );
      final runs = Uint8List.fromList([
        ...List.filled(40, 0xFF),
        1,
        2,
        3,
        ...List.filled(47, 0),
      ]);
      for (final bits in [noisy, runs]) {
        final sent = TinyImage.fromBits(40, 18, bits);
        final got = TinyImage.decode(sent.wire)!;
        for (var y = 0; y < 18; y++) {
          for (var x = 0; x < 40; x++) {
            expect(got.isBlack(x, y), sent.isBlack(x, y));
          }
        }
      }
    });

    test('every character fits GSM-7', () {
      final wire = TinyImage.fromRgba(
        _gray(56, 56, (x, y) => (x * 4 + y) % 256),
        56,
        56,
      ).wire;
      expect(RegExp(r'^[\[\]#:A-Za-z0-9_-]+$').hasMatch(wire), isTrue);
    });
  });

  group('what is not a picture', () {
    test('a newer version stays text', () {
      expect(TinyImage.isWire('[#I2:8x2:b]qlU'), isFalse);
      expect(TinyImage.decode('[#I2:8x2:b]qlU'), isNull);
      expect(TemplateWire.displayText('[#I2:8x2:b]qlU'), '[#I2:8x2:b]qlU');
    });

    test('ordinary text and a template are left alone', () {
      expect(TinyImage.isWire('[#I think so'), isFalse);
      expect(TemplateWire.displayText('سلام'), 'سلام');
    });

    test('a damaged payload does not draw', () {
      // One byte short, one byte long, and a packed run past the picture.
      expect(TinyImage.decode('[#I1:8x2:b]qg'), isNull);
      expect(TinyImage.decode('[#I1:8x2:b]qlVV'), isNull);
      expect(TinyImage.decode('[#I1:8x2:r]8QA'), isNull);
      expect(TinyImage.decode('[#I1:0x2:b]qlU'), isNull);
      expect(TinyImage.decode('[#I1:999x2:b]qlU'), isNull);
    });
  });

  test('every other surface reads the word, not the characters', () {
    expect(TemplateWire.displayText(_goldenChecker), TinyImage.label);
  });

  group('SMS parts', () {
    String wireOf(int length) => 'x' * length;

    test('the brackets count double', () {
      expect(TinyImage.smsParts(wireOf(158)), 1);
      expect(TinyImage.smsParts(wireOf(159)), 2);
    });

    test('a multi-part message carries 153 a part', () {
      expect(TinyImage.smsParts(wireOf(304)), 2);
      expect(TinyImage.smsParts(wireOf(305)), 3);
    });

    test('the offered sizes stay within what was promised', () {
      int partsAt(int edge) => TinyImage.smsParts(
        TinyImage.fromRgba(
          _gray(edge, edge, (x, y) => (x * 37 + y * 91) % 256),
          edge,
          edge,
        ).wire,
      );
      expect(partsAt(TinyImageSize.small.longEdge), lessThanOrEqualTo(2));
      expect(partsAt(TinyImageSize.medium.longEdge), lessThanOrEqualTo(4));
      expect(partsAt(TinyImageSize.large.longEdge), lessThanOrEqualTo(6));
    });
  });

  group('making the picture', () {
    test('black stays black and white stays white', () {
      final image = TinyImage.fromRgba(
        _gray(8, 8, (x, y) => x < 4 ? 0 : 255),
        8,
        8,
      );
      expect(image.isBlack(0, 0), isTrue);
      expect(image.isBlack(7, 7), isFalse);
    });

    test('a mid gray dithers to about half ink', () {
      const edge = 40;
      final image = TinyImage.fromRgba(
        _gray(edge, edge, (x, y) => 120 + (x + y) % 16),
        edge,
        edge,
      );
      var black = 0;
      for (var y = 0; y < edge; y++) {
        for (var x = 0; x < edge; x++) {
          if (image.isBlack(x, y)) black++;
        }
      }
      expect(black, inInclusiveRange(edge * edge ~/ 3, edge * edge * 2 ~/ 3));
    });

    test('proportions are kept, and a thin picture keeps one pixel', () {
      expect(TinyImage.fit(1000, 500, 56), (width: 56, height: 28));
      expect(TinyImage.fit(500, 1000, 56), (width: 28, height: 56));
      expect(TinyImage.fit(5000, 10, 40), (width: 40, height: 1));
      expect(TinyImage.fit(0, 0, 40), (width: 40, height: 40));
    });
  });
}
