import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:communication_super_app/core/services/image_picker_service.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';

import '../screens/photo_crop_screen.dart';

/// What the photo sheet was asked to do.
enum ContactPhotoAction { camera, gallery, remove }

/// «تغییر عکس» — the sheet Google Contacts opens when the avatar is tapped.
///
/// Three rows and no more: take one, choose one, and — only when there is one —
/// remove it. The remove row is the reason this is a sheet at all: it used to be
/// a second floating button stuck to the avatar, which put a delete control one
/// mis-tap away from the button next to it.
Future<ContactPhotoAction?> showContactPhotoSheet(
  BuildContext context, {
  required bool hasPhoto,
}) {
  return showModalBottomSheet<ContactPhotoAction>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('گرفتن عکس'),
              onTap: () =>
                  Navigator.pop(sheetContext, ContactPhotoAction.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('انتخاب از گالری'),
              onTap: () =>
                  Navigator.pop(sheetContext, ContactPhotoAction.gallery),
            ),
            if (hasPhoto) ...[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppColors.danger,
                ),
                title: const Text(
                  'حذف عکس',
                  style: TextStyle(color: AppColors.danger),
                ),
                onTap: () =>
                    Navigator.pop(sheetContext, ContactPhotoAction.remove),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// The whole «عکس مخاطب» flow: ask where from, pick, crop, hand back the bytes.
///
/// Returns a [ContactPhotoResult] describing what to do, or null when the user
/// backed out at any step — cancelling the crop must leave the contact's current
/// photo exactly as it was, not clear it.
Future<ContactPhotoResult?> pickContactPhoto(
  BuildContext context, {
  required bool hasPhoto,
}) async {
  final action = await showContactPhotoSheet(context, hasPhoto: hasPhoto);
  if (action == null || !context.mounted) return null;
  if (action == ContactPhotoAction.remove) {
    return const ContactPhotoResult.removed();
  }

  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  PickedImage? picked;
  try {
    picked = await ImagePickerService.instance.pick(
      action == ContactPhotoAction.camera
          ? PhotoSource.camera
          : PhotoSource.gallery,
    );
  } catch (e) {
    // Each failure gets its own sentence: «نشد» leaves the user with nothing to
    // do about it. A phone with no camera app is the one case worth naming.
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '$e'.contains('NO_CAMERA_APP')
              ? 'برنامه دوربینی روی این گوشی پیدا نشد'
              : 'انتخاب عکس ناموفق بود',
        ),
      ),
    );
    return null;
  }
  if (picked == null) return null; // user backed out of the picker

  final cropped = await navigator.push<Uint8List>(
    MaterialPageRoute(builder: (_) => PhotoCropScreen(image: picked!)),
  );
  if (cropped == null || cropped.isEmpty) return null;
  return ContactPhotoResult.picked(cropped);
}

/// The outcome of [pickContactPhoto].
///
/// "Removed" and "cancelled" are different answers and the caller must be able
/// to tell them apart — collapsing both to a null photo is how a cancelled crop
/// silently deletes the picture the contact already had.
class ContactPhotoResult {
  const ContactPhotoResult.picked(this.bytes) : removed = false;
  const ContactPhotoResult.removed() : bytes = null, removed = true;

  final Uint8List? bytes;
  final bool removed;
}
