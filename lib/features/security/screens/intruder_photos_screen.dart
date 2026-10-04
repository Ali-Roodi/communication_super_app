import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure/repositories/intruder_repository.dart';
import 'package:communication_super_app/features/secure/widgets/secure_locked_view.dart';

/// «عکس‌های ورود ناموفق» (matrix row 32): what the cameras saw after wrong
/// PIN entries, with date and time. Inside the secure section only.
class IntruderPhotosScreen extends StatefulWidget {
  const IntruderPhotosScreen({super.key});

  @override
  State<IntruderPhotosScreen> createState() => _IntruderPhotosScreenState();
}

class _IntruderPhotosScreenState extends State<IntruderPhotosScreen> {
  final _repo = IntruderRepository();
  Future<List<IntruderPhoto>>? _items;

  void _load() {
    _items = () async {
      await _repo.collect();
      return _repo.list();
    }();
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف همه عکس‌ها؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _repo.deleteAll();
    if (mounted) setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    final open = context.select<SecureSessionBloc, bool>(
      (b) => b.state.isUnlocked,
    );
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: RtlAppBar(
          title: 'عکس‌های ورود ناموفق',
          actions: [
            if (open)
              IconButton(
                tooltip: 'حذف همه',
                icon: const Icon(Icons.delete_outline),
                onPressed: _deleteAll,
              ),
          ],
        ),
        body: !open
            ? const SecureLockedView(
                message: 'عکس‌ها داخل بخش امن هستند. بخش امن را باز کنید.',
              )
            : FutureBuilder<List<IntruderPhoto>>(
                future: _items ??= (() {
                  _load();
                  return _items!;
                })(),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final items = snap.data ?? const <IntruderPhoto>[];
                  if (items.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'تا حالا ورود ناموفقی ثبت نشده است.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  final events = <int, List<IntruderPhoto>>{};
                  for (final p in items) {
                    events.putIfAbsent(p.takenAt, () => []).add(p);
                  }
                  return ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      for (final e in events.entries)
                        _EventCard(at: e.key, photos: e.value, repo: _repo),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.at,
    required this.photos,
    required this.repo,
  });
  final int at;
  final List<IntruderPhoto> photos;
  final IntruderRepository repo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final when = DateTime.fromMillisecondsSinceEpoch(at);
    final failures = photos.first.failures;
    final shots = photos.where((p) => p.hasPhoto).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              DateFormatter.formatDateAndTime(when),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              '${PersianUtils.toPersianNumber('$failures')} رمز اشتباه پشت‌سرهم',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 10),
            if (shots.isEmpty)
              Text(
                'عکسی گرفته نشد (دسترسی دوربین داده نشده یا دوربین در دسترس نبود).',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              )
            else
              Row(
                children: [
                  for (final p in shots)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _Shot(photo: p, repo: repo),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Shot extends StatelessWidget {
  const _Shot({required this.photo, required this.repo});
  final IntruderPhoto photo;
  final IntruderRepository repo;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: repo.photo(photo.id),
      builder: (context, snap) {
        final bytes = snap.data;
        return Column(
          children: [
            AspectRatio(
              aspectRatio: 3 / 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: bytes == null
                    ? const ColoredBox(color: Colors.black12)
                    : GestureDetector(
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (_) => Dialog(
                            child: InteractiveViewer(
                              child: Image.memory(bytes),
                            ),
                          ),
                        ),
                        child: Image.memory(bytes, fit: BoxFit.cover),
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              photo.camera == 'front' ? 'دوربین جلو' : 'دوربین پشت',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        );
      },
    );
  }
}
