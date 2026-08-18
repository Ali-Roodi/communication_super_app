import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:communication_super_app/core/services/image_picker_service.dart';

/// «برش عکس» — the editor between picking a photo and putting it on a contact.
///
/// Google Contacts' photo step, and the same three things it lets you do: move
/// the picture under a circular window, pinch it bigger or smaller, and turn it
/// a quarter at a time. Nothing else — a contact photo is a face in a circle,
/// and filters or free-form rectangles would be answering a question nobody
/// asked here.
///
/// **The gesture is the crop; the pixels are cut natively.** This screen never
/// touches the image data: it hands `ImagePickerService.crop` the rotation and a
/// *normalised* rectangle, and Kotlin rotates, cuts and re-encodes. Cropping
/// here would mean rasterising through `dart:ui` at preview resolution and
/// shipping a PNG — a bigger, softer photo for more work.
///
/// Pops with the finished JPEG bytes, or null if the user backed out.
class PhotoCropScreen extends StatefulWidget {
  const PhotoCropScreen({super.key, required this.image});

  final PickedImage image;

  @override
  State<PhotoCropScreen> createState() => _PhotoCropScreenState();
}

class _PhotoCropScreenState extends State<PhotoCropScreen> {
  /// Quarter turns applied to the image, 0–3. Turns rather than degrees because
  /// that is what `RotatedBox` takes; the native call gets ×90.
  int _turns = 0;

  /// How much bigger than "just covers the window" the picture is drawn.
  ///
  /// Never below 1: the window must always be full of image, so zooming out
  /// past cover would leave empty space in a contact photo.
  double _scale = 1;

  /// Top-left of the drawn image relative to the window's top-left. Always ≤ 0
  /// on both axes — see [_clamp].
  Offset _offset = Offset.zero;

  // Gesture start values. Every update is recomputed from these rather than
  // accumulated, so a long pinch cannot drift.
  double _scaleAtStart = 1;
  Offset _offsetAtStart = Offset.zero;
  Offset _focalAtStart = Offset.zero;

  /// Side of the crop window, measured during layout.
  ///
  /// Assigned from `build` without `setState` (the same pattern the conversation
  /// screen uses for the keyboard height): it is only ever *read* on a later
  /// frame — by the confirm button, which lives in a different subtree — and
  /// calling setState from build would loop.
  double _side = 1;

  bool _busy = false;

  /// The largest zoom before the picture is being enlarged rather than framed.
  /// The native preview is 1536 px on its longest edge and the output 512, so
  /// 3× is still pixel-for-pixel.
  static const double _kMaxScale = 3;

  /// The image's aspect **after** the quarter turns.
  double get _aspect {
    final w = widget.image.width.toDouble();
    final h = widget.image.height.toDouble();
    if (w <= 0 || h <= 0) return 1;
    return _turns.isEven ? w / h : h / w;
  }

  /// The drawn size for the current window and zoom.
  ///
  /// Cover, not contain: the shorter edge is exactly the window, so the window
  /// is always full and only the longer edge has slack to pan along.
  Size get _displaySize {
    final aspect = _aspect;
    final base = aspect >= 1
        ? Size(_side * aspect, _side)
        : Size(_side, _side / aspect);
    return Size(base.width * _scale, base.height * _scale);
  }

  /// Keeps the window inside the picture on both axes.
  Offset _clamp(Offset offset) {
    final size = _displaySize;
    return Offset(
      offset.dx.clamp(math.min(_side - size.width, 0.0), 0.0),
      offset.dy.clamp(math.min(_side - size.height, 0.0), 0.0),
    );
  }

  /// The framing a photo opens on: the **middle** of the picture.
  ///
  /// Not the top-left corner. A portrait photo is taller than the window, and
  /// starting at the corner opened every one of them on the forehead with the
  /// face cut off below — which is exactly the crop nobody wants and everybody
  /// then has to drag out of.
  Offset get _centred {
    final size = _displaySize;
    return Offset((_side - size.width) / 2, (_side - size.height) / 2);
  }

  void _rotate() {
    HapticFeedback.selectionClick();
    setState(() {
      _turns = (_turns + 1) % 4;
      // Re-fit rather than carrying the framing through a quarter turn: the
      // slack axis has just swapped, so a preserved offset would be measured
      // against the wrong edge and the picture would jump anyway.
      _scale = 1;
      _offset = _centred;
    });
  }

  void _onScaleStart(ScaleStartDetails details) {
    _scaleAtStart = _scale;
    _offsetAtStart = _offset;
    _focalAtStart = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final next = (_scaleAtStart * details.scale).clamp(1.0, _kMaxScale);
    final ratio = next / _scaleAtStart;
    // Zoom about the point the fingers landed on, then follow wherever they
    // moved. One expression from the start values — nothing accumulates.
    final zoomed = _focalAtStart - (_focalAtStart - _offsetAtStart) * ratio;
    final panned = zoomed + (details.localFocalPoint - _focalAtStart);
    setState(() {
      _scale = next;
      _offset = _clamp(panned);
    });
  }

  Future<void> _confirm() async {
    if (_busy) return;
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    Future<void> fail() async {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('برش عکس ناموفق بود')),
      );
    }

    try {
      final size = _displaySize;
      final bytes = await ImagePickerService.instance.crop(
        bytes: widget.image.bytes,
        rotation: _turns * 90,
        // Normalised against the DRAWN size, so the answer does not depend on
        // this screen's pixel dimensions.
        left: (-_offset.dx) / size.width,
        top: (-_offset.dy) / size.height,
        // The window is `_side` wide and the shorter drawn edge is
        // `_side * _scale`, so the window is 1/scale of the shorter edge.
        size: 1 / _scale,
      );
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        await fail();
        return;
      }
      navigator.pop(bytes);
    } catch (_) {
      await fail();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // A square window, inset so the circle never touches the
                    // screen edges — the picture itself is the drag handle and
                    // it needs somewhere to be grabbed from.
                    final side = math.max(
                      1.0,
                      math.min(constraints.maxWidth, constraints.maxHeight) -
                          32,
                    );
                    if (side != _side) {
                      final first = _side == 1;
                      _side = side;
                      // The first layout is where the opening framing is
                      // decided — `_side` is not known before it, so the centre
                      // cannot be computed in initState. A later resize (device
                      // rotation) only re-clamps, so it does not throw away a
                      // framing the user has already chosen.
                      _offset = first ? _centred : _clamp(_offset);
                    }
                    return Center(child: _buildWindow(side));
                  },
                ),
              ),
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 16, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            tooltip: 'انصراف',
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'برش عکس',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
                // Under the title, not beside it: side by side the hint pushed
                // «برش عکس» into two lines on a phone-width bar.
                Text(
                  'بکشید تا جابه‌جا شود · دو انگشتی برای بزرگ‌نمایی',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWindow(double side) {
    final size = _displaySize;
    return GestureDetector(
      // One recognizer for both gestures on purpose: `ScaleGestureRecognizer`
      // reports a one-finger drag as a scale of 1 with a moving focal point, so
      // pan and pinch are the same stream and cannot fight each other in the
      // arena. There is nothing else on this screen to lose the arena to.
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      child: SizedBox(
        width: side,
        height: side,
        child: ClipRect(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: _offset.dx,
                top: _offset.dy,
                width: size.width,
                height: size.height,
                // RotatedBox rotates the *layout*, so on an odd turn the child
                // is measured with transposed constraints — which is exactly
                // what `_aspect` already accounts for. `Transform` would rotate
                // the painting only and leave the box the wrong way round.
                child: RotatedBox(
                  quarterTurns: _turns,
                  child: Image.memory(
                    widget.image.bytes,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              // The circle is what the user is framing for: a contact photo is
              // drawn round everywhere in this app, so cropping against a square
              // and discovering afterwards that the haircut is gone is the wrong
              // order.
              const Positioned.fill(child: IgnorePointer(child: _CircleMask())),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton.icon(
            onPressed: _busy ? null : _rotate,
            // CW, because `RotatedBox` turns clockwise — an icon pointing the
            // other way is a promise the button does not keep.
            icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
            label: const Text('چرخش'),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
          ),
          FilledButton(
            onPressed: _busy ? null : _confirm,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('تأیید'),
          ),
        ],
      ),
    );
  }
}

/// Dims everything outside the circle the photo will be shown in.
class _CircleMask extends StatelessWidget {
  const _CircleMask();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _MaskPainter());
}

class _MaskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = Path()..addOval(rect.deflate(1));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(rect), circle),
      Paint()..color = const Color(0xB3000000),
    );
    canvas.drawPath(
      circle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white70,
    );
  }

  @override
  bool shouldRepaint(_MaskPainter oldDelegate) => false;
}
