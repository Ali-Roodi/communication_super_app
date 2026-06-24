import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import '../bloc/blocked_numbers_bloc.dart';
import '../models/blocked_number_model.dart';

/// Item 13 — full blocked-numbers management screen.
///
/// Backed by the globally-provided [BlockedNumbersBloc]. Lets the user block a
/// new number and unblock existing ones, mirroring the Google Phone layout:
/// an info banner, an add-number row, then the list of blocked numbers.
class BlockedNumbersScreen extends StatefulWidget {
  const BlockedNumbersScreen({super.key});

  @override
  State<BlockedNumbersScreen> createState() => _BlockedNumbersScreenState();
}

class _BlockedNumbersScreenState extends State<BlockedNumbersScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _block() {
    final raw = _controller.text.trim();
    if (BlockedNumberModel.normalize(raw).isEmpty) return;
    context.read<BlockedNumbersBloc>().add(BlockNumber(raw));
    _controller.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'شماره‌های مسدود'),
        body: Column(
          children: [
            // ── Info banner ──────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.4,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'تماس‌ها و پیامک‌های شماره‌های مسدودشده رد می‌شوند.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
            // ── Add number row ───────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: TextField(
                        controller: _controller,
                        keyboardType: TextInputType.phone,
                        textAlign: TextAlign.right,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[\d+\-\s()]'),
                          ),
                        ],
                        onSubmitted: (_) => _block(),
                        decoration: const InputDecoration(
                          hintText: 'افزودن شماره',
                          prefixIcon: Icon(Icons.dialpad),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _block,
                    child: const Text('مسدود کردن'),
                  ),
                ],
              ),
            ),
            // ── Blocked list ─────────────────────────────────────────
            Expanded(
              child: BlocBuilder<BlockedNumbersBloc, BlockedNumbersState>(
                builder: (context, state) {
                  if (state is BlockedNumbersLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (state is BlockedNumbersError) {
                    return Center(child: Text(state.message));
                  }
                  if (state is BlockedNumbersLoaded) {
                    if (state.numbers.isEmpty) {
                      return Center(
                        child: Text(
                          'شماره مسدودی وجود ندارد',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    return ListView.builder(
                      itemCount: state.numbers.length,
                      itemBuilder: (context, i) =>
                          _BlockedTile(number: state.numbers[i]),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlockedTile extends StatelessWidget {
  final BlockedNumberModel number;
  const _BlockedTile({required this.number});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.block, color: AppColors.callRejectRed),
      title: Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          PersianUtils.toPersianNumber(number.phoneNumber),
          textAlign: TextAlign.right,
        ),
      ),
      trailing: TextButton(
        onPressed: () => context.read<BlockedNumbersBloc>().add(
          UnblockNumber(number.normalized),
        ),
        child: const Text('رفع مسدودی'),
      ),
    );
  }
}
