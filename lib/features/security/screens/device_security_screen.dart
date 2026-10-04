import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';

import '../models/device_security_report.dart';
import '../services/security_bridge.dart';

/// «کنترل امنیت سامانه» (matrix row 29): how far this phone can be trusted
/// with the secure section — root, tampering, screen readers, locks,
/// updates, where the keys live, and whether هم‌رسان holds the roles that
/// keep encrypted and hidden traffic out of other apps.
class DeviceSecurityScreen extends StatefulWidget {
  const DeviceSecurityScreen({super.key, this.bridge = const SecurityBridge()});

  final SecurityBridge bridge;

  @override
  State<DeviceSecurityScreen> createState() => _DeviceSecurityScreenState();
}

class _DeviceSecurityScreenState extends State<DeviceSecurityScreen> {
  late Future<DeviceSecurityReport?> _report = _check();

  Future<DeviceSecurityReport?> _check() async {
    final facts = await widget.bridge.deviceReport();
    return facts == null ? null : DeviceSecurityReport.fromFacts(facts);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: RtlAppBar(
          title: 'کنترل امنیت سامانه',
          actions: [
            IconButton(
              tooltip: 'بررسی دوباره',
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(() => _report = _check()),
            ),
          ],
        ),
        body: FutureBuilder<DeviceSecurityReport?>(
          future: _report,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final report = snap.data;
            if (report == null) {
              return const Center(child: Text('بررسی امنیت ممکن نشد.'));
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _Summary(report),
                const SizedBox(height: 12),
                for (final f in report.findings) _FindingTile(f),
              ],
            );
          },
        ),
      ),
    );
  }
}

Color _colorOf(SecurityLevel level, ColorScheme scheme) => switch (level) {
  SecurityLevel.ok => Colors.green.shade700,
  SecurityLevel.info => scheme.primary,
  SecurityLevel.warn => Colors.orange.shade800,
  SecurityLevel.risk => scheme.error,
};

IconData _iconOf(SecurityLevel level) => switch (level) {
  SecurityLevel.ok => Icons.check_circle_outline,
  SecurityLevel.info => Icons.info_outline,
  SecurityLevel.warn => Icons.warning_amber_rounded,
  SecurityLevel.risk => Icons.gpp_bad_outlined,
};

class _Summary extends StatelessWidget {
  const _Summary(this.report);
  final DeviceSecurityReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final worst = report.worst;
    final color = _colorOf(worst, scheme);
    final title = switch (worst) {
      SecurityLevel.ok || SecurityLevel.info => 'وضعیت امنیت گوشی خوب است',
      SecurityLevel.warn => 'چند مورد امنیت را کم می‌کند',
      SecurityLevel.risk => 'بخش امن روی این گوشی قابل اعتماد نیست',
    };
    String n(int v) => PersianUtils.toPersianNumber('$v');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            worst == SecurityLevel.risk
                ? Icons.gpp_bad
                : worst == SecurityLevel.warn
                ? Icons.gpp_maybe
                : Icons.verified_user,
            color: color,
            size: 40,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${n(report.count(SecurityLevel.risk))} خطر · '
                  '${n(report.count(SecurityLevel.warn))} هشدار · '
                  '${n(report.count(SecurityLevel.ok))} سالم',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                Text(
                  '${report.model} · '
                  '${DateFormatter.formatTime(report.checkedAt)}',
                  textDirection: TextDirection.rtl,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile(this.f);
  final SecurityFinding f;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_iconOf(f.level), color: _colorOf(f.level, scheme)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  f.detail,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
