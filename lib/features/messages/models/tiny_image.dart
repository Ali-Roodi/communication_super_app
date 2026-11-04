import 'dart:convert';
import 'dart:typed_data';

/// How large a tiny image is sent. Each step about doubles what it costs.
enum TinyImageSize {
  small(40, 'کوچک'),
  medium(56, 'متوسط'),
  large(72, 'بزرگ');

  const TinyImageSize(this.longEdge, this.label);

  /// Pixels along the longer side.
  final int longEdge;
  final String label;
}

/// A tiny black-and-white picture that travels as the text of an SMS (matrix
/// row 42). This app has no MMS, so the picture has to fit in characters.
///
/// ```text
/// [#I1:56x42:b]<base64url, no padding>
/// ```
///
/// * `#I1` — this format, version 1. A newer version does not match, so it
///   renders as its raw text instead of as a wrong picture.
/// * `56x42` — width and height in pixels.
/// * `b` — the payload is the raw bits; `r` — PackBits over those bits,
///   whichever came out shorter. A dithered photo rarely compresses; a drawing
///   or a screenshot does.
/// * the bits — row by row, most significant bit first, with no row padding.
///   1 is black.
///
/// Every character is in the GSM-7 alphabet, so a part carries 153 characters
/// rather than the 67 of a Persian message: that is the whole reason this is
/// practical. A phone without this app shows the text as it arrived.
///
/// **Mirror:** [sigil], the shape of [isWire] and [label] are repeated in
/// `TemplateWire.kt`, which is what names it in a notification.
class TinyImage {
  const TinyImage._(this.width, this.height, this._bits);

  static const String sigil = '[#I';

  /// What every surface that cannot draw it says instead.
  static const String label = 'تصویر';

  static const int _maxEdge = 128;

  static final RegExp _wire = RegExp(
    r'^\[#I1:(\d{1,3})x(\d{1,3}):([br])\]([A-Za-z0-9_-]+)$',
  );

  final int width;
  final int height;
  final Uint8List _bits;

  static int _byteCount(int width, int height) => (width * height + 7) ~/ 8;

  /// Whether a message body is one of these. Cheap enough for an inbox row.
  static bool isWire(String body) =>
      body.startsWith(sigil) && _wire.hasMatch(body);

  /// The picture in [body], or null when it is not one or its payload is
  /// damaged.
  static TinyImage? decode(String body) {
    if (!body.startsWith(sigil)) return null;
    final match = _wire.firstMatch(body);
    if (match == null) return null;
    final width = int.parse(match.group(1)!);
    final height = int.parse(match.group(2)!);
    if (width < 1 || height < 1 || width > _maxEdge || height > _maxEdge) {
      return null;
    }
    final Uint8List payload;
    try {
      payload = base64Url.decode(base64Url.normalize(match.group(4)!));
    } on FormatException {
      return null;
    }
    final expected = _byteCount(width, height);
    final bits = match.group(3) == 'r' ? _unpack(payload, expected) : payload;
    if (bits == null || bits.length != expected) return null;
    return TinyImage._(width, height, bits);
  }

  /// A picture from [rgba] (4 bytes a pixel), with the contrast stretched and
  /// Floyd-Steinberg dithering: at this size a plain threshold turns a face
  /// into a blot.
  factory TinyImage.fromRgba(Uint8List rgba, int width, int height) {
    final gray = Float64List(width * height);
    final histogram = List<int>.filled(256, 0);
    for (var i = 0; i < gray.length; i++) {
      final at = i * 4;
      final value =
          0.299 * rgba[at] + 0.587 * rgba[at + 1] + 0.114 * rgba[at + 2];
      gray[i] = value;
      histogram[value.round().clamp(0, 255)]++;
    }

    // The darkest and lightest 2 % are outliers, not the range of the photo.
    final margin = gray.length * 2 ~/ 100;
    var low = 0;
    for (var seen = 0; low < 255; low++) {
      seen += histogram[low];
      if (seen > margin) break;
    }
    var high = 255;
    for (var seen = 0; high > 0; high--) {
      seen += histogram[high];
      if (seen > margin) break;
    }
    final range = high > low ? (high - low).toDouble() : 255.0;
    final floor = high > low ? low : 0;
    for (var i = 0; i < gray.length; i++) {
      gray[i] = ((gray[i] - floor) * 255 / range).clamp(0.0, 255.0);
    }

    final bits = Uint8List(_byteCount(width, height));
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final old = gray[i];
        final black = old < 128;
        if (black) bits[i >> 3] |= 0x80 >> (i & 7);
        final error = old - (black ? 0 : 255);
        if (x + 1 < width) gray[i + 1] += error * 7 / 16;
        if (y + 1 < height) {
          if (x > 0) gray[i + width - 1] += error * 3 / 16;
          gray[i + width] += error * 5 / 16;
          if (x + 1 < width) gray[i + width + 1] += error * 1 / 16;
        }
      }
    }
    return TinyImage._(width, height, bits);
  }

  /// A picture from its packed bits, as [decode] would hold them.
  factory TinyImage.fromBits(int width, int height, Uint8List bits) {
    assert(bits.length == _byteCount(width, height));
    return TinyImage._(width, height, bits);
  }

  /// The pixel size of a picture fitted to [longEdge], keeping its proportions.
  static ({int width, int height}) fit(
    int sourceWidth,
    int sourceHeight,
    int longEdge,
  ) {
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return (width: longEdge, height: longEdge);
    }
    if (sourceWidth >= sourceHeight) {
      final height = (sourceHeight * longEdge / sourceWidth).round();
      return (width: longEdge, height: height < 1 ? 1 : height);
    }
    final width = (sourceWidth * longEdge / sourceHeight).round();
    return (width: width < 1 ? 1 : width, height: longEdge);
  }

  bool isBlack(int x, int y) {
    final i = y * width + x;
    return _bits[i >> 3] & (0x80 >> (i & 7)) != 0;
  }

  /// The SMS body.
  String get wire {
    final packed = _pack(_bits);
    final usePacked = packed.length < _bits.length;
    final payload = base64Url
        .encode(usePacked ? packed : _bits)
        .replaceAll('=', '');
    return '[#I1:${width}x$height:${usePacked ? 'r' : 'b'}]$payload';
  }

  /// How many SMS [wire] goes out as: `[` and `]` take two GSM-7 septets each.
  static int smsParts(String wire) {
    final septets = wire.length + 2;
    return septets <= 160 ? 1 : (septets + 152) ~/ 153;
  }

  // ── PackBits ──────────────────────────────────────────────────────────────

  static Uint8List _pack(Uint8List input) {
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < input.length) {
      var run = 1;
      while (i + run < input.length &&
          run < 128 &&
          input[i + run] == input[i]) {
        run++;
      }
      if (run >= 2) {
        out.addByte(257 - run);
        out.addByte(input[i]);
        i += run;
        continue;
      }
      var literal = 1;
      while (i + literal < input.length &&
          literal < 128 &&
          (i + literal + 1 >= input.length ||
              input[i + literal] != input[i + literal + 1])) {
        literal++;
      }
      out.addByte(literal - 1);
      out.add(Uint8List.sublistView(input, i, i + literal));
      i += literal;
    }
    return out.takeBytes();
  }

  /// Null when [input] is damaged. Stops at [expected] bytes, so a bad payload
  /// cannot make it allocate more than one picture.
  static Uint8List? _unpack(Uint8List input, int expected) {
    final out = Uint8List(expected);
    var o = 0;
    var i = 0;
    while (i < input.length) {
      final header = input[i++];
      if (header < 128) {
        final count = header + 1;
        if (i + count > input.length || o + count > expected) return null;
        out.setRange(o, o + count, input, i);
        i += count;
        o += count;
      } else if (header > 128) {
        final count = 257 - header;
        if (i >= input.length || o + count > expected) return null;
        out.fillRange(o, o + count, input[i++]);
        o += count;
      }
    }
    return o == expected ? out : null;
  }
}
