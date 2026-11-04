import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:communication_super_app/core/services/app_handoff.dart';
import 'package:communication_super_app/core/services/image_picker_service.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';

import '../../models/tiny_image.dart';
import 'tiny_image_view.dart';

/// «تصویر کوچک» in the composer's + sheet: picks a picture from the gallery and
/// shows what it becomes and how many SMS it costs. The body to send, or null
/// when the user backed out.
Future<String?> pickTinyImage(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final PickedImage? picked;
  try {
    picked = await AppHandoff.run(
      () => ImagePickerService.instance.pick(PhotoSource.gallery),
    );
  } on PlatformException {
    messenger.showSnackBar(const SnackBar(content: Text('تصویر باز نشد')));
    return null;
  }
  if (picked == null || !context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TinyImageSheet(picked: picked!),
  );
}

/// Decodes [picked] down to [size]. Null when the bytes are not a picture.
Future<TinyImage?> _render(PickedImage picked, TinyImageSize size) async {
  final fit = TinyImage.fit(picked.width, picked.height, size.longEdge);
  try {
    final codec = await ui.instantiateImageCodec(
      picked.bytes,
      targetWidth: fit.width,
      targetHeight: fit.height,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData();
    final width = frame.image.width;
    final height = frame.image.height;
    frame.image.dispose();
    codec.dispose();
    if (data == null) return null;
    return TinyImage.fromRgba(data.buffer.asUint8List(), width, height);
  } on Exception {
    return null;
  }
}

class _TinyImageSheet extends StatefulWidget {
  const _TinyImageSheet({required this.picked});

  final PickedImage picked;

  @override
  State<_TinyImageSheet> createState() => _TinyImageSheetState();
}

class _TinyImageSheetState extends State<_TinyImageSheet> {
  final Map<TinyImageSize, TinyImage> _images = {};
  TinyImageSize _size = TinyImageSize.medium;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _select(_size);
  }

  Future<void> _select(TinyImageSize size) async {
    setState(() => _size = size);
    if (_images.containsKey(size)) return;
    final image = await _render(widget.picked, size);
    if (!mounted) return;
    setState(() {
      if (image == null) {
        _failed = true;
      } else {
        _images[size] = image;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = _images[_size];
    final wire = image?.wire;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'تصویر کوچک',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 240,
                child: Center(
                  child: _failed
                      ? const Text('این تصویر باز نشد')
                      : image == null
                      ? const SizedBox.shrink()
                      : TinyImageView(image: image, maxEdge: 240),
                ),
              ),
              const SizedBox(height: 16),
              SegmentedButton<TinyImageSize>(
                segments: [
                  for (final size in TinyImageSize.values)
                    ButtonSegment(value: size, label: Text(size.label)),
                ],
                selected: {_size},
                showSelectedIcon: false,
                onSelectionChanged: (s) => _select(s.first),
              ),
              const SizedBox(height: 12),
              if (wire != null)
                Text(
                  '${PersianUtils.toPersianNumber('${TinyImage.smsParts(wire)}')} پیامک برای هر گیرنده',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              const SizedBox(height: 4),
              Text(
                'گیرنده تصویر را فقط در هم‌رسان می‌بیند؛ در برنامه‌های دیگر متنی نامفهوم نشان داده می‌شود.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: wire == null
                    ? null
                    : () => Navigator.of(context).pop(wire),
                icon: const Icon(Icons.send_outlined),
                label: const Text('ارسال'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
