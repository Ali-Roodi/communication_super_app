import 'package:flutter/material.dart';

import '../../models/tiny_image.dart';

/// Draws a [TinyImage], always black on white: in the text colour a dark bubble
/// would show a photo as its negative.
class TinyImageView extends StatelessWidget {
  const TinyImageView({super.key, required this.image, required this.maxEdge});

  final TinyImage image;

  /// The most the longer side may take on screen.
  final double maxEdge;

  /// Whole screen pixels per image pixel look like a picture; a fraction of one
  /// leaves uneven rows.
  static const double _targetEdge = 240;

  @override
  Widget build(BuildContext context) {
    final long = image.width > image.height ? image.width : image.height;
    final whole = (_targetEdge / long).floorToDouble();
    final fitted = maxEdge / long;
    final scale = whole < fitted ? whole : fitted;
    return Semantics(
      image: true,
      label: TinyImage.label,
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: CustomPaint(
            size: Size(image.width * scale, image.height * scale),
            painter: _TinyImagePainter(image),
          ),
        ),
      ),
    );
  }
}

class _TinyImagePainter extends CustomPainter {
  _TinyImagePainter(this.image);

  final TinyImage image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final ink = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    final pixelWidth = size.width / image.width;
    final pixelHeight = size.height / image.height;
    for (var y = 0; y < image.height; y++) {
      var x = 0;
      while (x < image.width) {
        if (!image.isBlack(x, y)) {
          x++;
          continue;
        }
        final start = x;
        while (x < image.width && image.isBlack(x, y)) {
          x++;
        }
        canvas.drawRect(
          Rect.fromLTRB(
            start * pixelWidth,
            y * pixelHeight,
            x * pixelWidth,
            (y + 1) * pixelHeight,
          ),
          ink,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TinyImagePainter oldDelegate) =>
      !identical(oldDelegate.image, image);
}
