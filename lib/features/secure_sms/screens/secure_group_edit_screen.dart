import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure/repositories/secure_group_store.dart';

import '../bloc/secure_messages_bloc.dart';
import '../services/secure_identities.dart';
import 'secure_group_screen.dart';

/// «گروه رمز جدید», or the creator editing its group. Members come from the
/// key bank (directory members) and the hidden phonebook (those the bank
/// has a key for): a group message is encrypted to each member's key.
class SecureGroupEditScreen extends StatefulWidget {
  const SecureGroupEditScreen({super.key, this.group});

  /// Null for a new group.
  final SecureGroup? group;

  @override
  State<SecureGroupEditScreen> createState() => _SecureGroupEditScreenState();
}

class _SecureGroupEditScreenState extends State<SecureGroupEditScreen> {
  late final SecureMessagesBloc _bloc;
  late final _name = TextEditingController(text: widget.group?.name);
  late SecureGroupMode _mode = widget.group?.mode ?? SecureGroupMode.chat;
  late final Set<String> _selected = {
    for (final m in widget.group?.members ?? const <SecureGroupMember>[])
      m.phone,
  };
  String _filter = '';
  bool _saving = false;

  bool get _editing => widget.group != null;

  @override
  void initState() {
    super.initState();
    _bloc = context.read<SecureMessagesBloc>()
      ..add(const SecureLoadGroupCandidates());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save(List<SecurePeer> candidates) {
    final name = _name.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    if (name.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('نام گروه را وارد کنید.')),
      );
      return;
    }
    if (_selected.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('دست‌کم یک عضو انتخاب کنید.')),
      );
      return;
    }
    final chosen = [
      for (final p in candidates)
        if (_selected.contains(p.phone)) p,
    ];
    if (_editing) {
      final known = {for (final p in candidates) p.phone};
      _bloc.add(
        SecureEditGroup(
          widget.group!.id,
          name,
          chosen,
          keep: [
            for (final phone in _selected)
              if (!known.contains(phone)) phone,
          ],
        ),
      );
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    _bloc.add(SecureCreateGroup(name, _mode, chosen));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocListener<SecureMessagesBloc, SecureMessagesState>(
        listenWhen: (a, b) =>
            !_editing &&
            a.startedGroupSeq != b.startedGroupSeq &&
            b.startedGroupId != null,
        listener: (context, state) => Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => SecureGroupScreen(
              id: state.startedGroupId!,
              name: _name.text.trim(),
            ),
          ),
        ),
        child: BlocBuilder<SecureMessagesBloc, SecureMessagesState>(
          builder: (context, state) {
            final candidates = state.candidates;
            final known = {for (final p in candidates) p.phone};
            // Members whose key the bank no longer has stay listed, so an
            // edit never drops them silently.
            final orphans = [
              for (final m
                  in widget.group?.members ?? const <SecureGroupMember>[])
                if (!known.contains(m.phone)) m.phone,
            ];
            final q = _filter.trim();
            final shown = [
              for (final p in candidates)
                if (q.isEmpty ||
                    p.name.contains(q) ||
                    p.phone.contains(PersianUtils.toEnglishNumber(q)))
                  p,
            ];
            final count = _selected.length;
            return Scaffold(
              appBar: RtlAppBar(
                title: _editing ? 'ویرایش گروه' : 'گروه رمز جدید',
                actions: [
                  TextButton(
                    onPressed: _saving ? null : () => _save(candidates),
                    child: Text(_editing ? 'ذخیره' : 'ساخت'),
                  ),
                ],
              ),
              body: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: TextField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'نام گروه',
                        prefixIcon: Icon(Icons.group_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SegmentedButton<SecureGroupMode>(
                      segments: const [
                        ButtonSegment(
                          value: SecureGroupMode.chat,
                          label: Text('گفتگوی گروهی'),
                          icon: Icon(Icons.forum_outlined),
                        ),
                        ButtonSegment(
                          value: SecureGroupMode.announce,
                          label: Text('اطلاع‌رسانی'),
                          icon: Icon(Icons.campaign_outlined),
                        ),
                      ],
                      selected: {_mode},
                      // Fixed once made: members already hold the old mode.
                      onSelectionChanged: _editing
                          ? null
                          : (s) => setState(() => _mode = s.single),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                    child: Text(
                      _mode == SecureGroupMode.chat
                          ? 'پاسخ هر عضو به همهٔ اعضا می‌رسد؛ هر پیام به ازای هر '
                                'عضو یک پیامک هزینه دارد.'
                          : 'فقط شما برای همه می‌فرستید؛ پاسخ اعضا فقط به شما '
                                'می‌رسد.',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text(
                      count == 0
                          ? 'اعضا'
                          : 'اعضا · ${PersianUtils.toPersianNumber('$count')} نفر',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'جستجوی نام یا شماره',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (v) => setState(() => _filter = v),
                    ),
                  ),
                  for (final phone in orphans)
                    CheckboxListTile(
                      value: _selected.contains(phone),
                      onChanged: (on) => setState(
                        () => on == true
                            ? _selected.add(phone)
                            : _selected.remove(phone),
                      ),
                      title: Text(state.nameOf(phone)),
                      subtitle: const Text('کلیدش دیگر در بانک کلید شما نیست'),
                    ),
                  for (final p in shown)
                    CheckboxListTile(
                      value: _selected.contains(p.phone),
                      onChanged: (on) => setState(
                        () => on == true
                            ? _selected.add(p.phone)
                            : _selected.remove(p.phone),
                      ),
                      secondary: CircleAvatar(
                        backgroundColor: scheme.primaryContainer,
                        child: Text(
                          PersianUtils.getInitials(p.name),
                          style: TextStyle(color: scheme.onPrimaryContainer),
                        ),
                      ),
                      title: Text(p.name),
                      subtitle: Text(
                        '${PersianUtils.displayPhone(p.phone)} · '
                        '${p.sourceName ?? ''}',
                      ),
                    ),
                  if (candidates.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'کسی با کلید در بانک کلید یا دفترچه مخفی نیست.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
