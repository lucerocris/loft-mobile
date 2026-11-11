import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/pairing.dart';
import '../notify/watcher.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

Future<void> showSettingsSheet(BuildContext context, WidgetRef ref) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _Settings(),
    );

class _Settings extends ConsumerStatefulWidget {
  const _Settings();
  @override
  ConsumerState<_Settings> createState() => _SettingsState();
}

class _SettingsState extends ConsumerState<_Settings> {
  bool? _alerts;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Alerts.enabled().then((v) => mounted ? setState(() => _alerts = v) : null);
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    final err = await Alerts.setEnabled(on);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _alerts = err == null ? on : false;
    });
    if (err != null) toast(context, err, error: true);
  }

  Future<void> _unpair() async {
    final ok = await confirmDanger(context,
        title: 'Unpair this phone?', body: 'Loft forgets the laptop\'s address and code. Revoke it on the laptop too (Phone access).', action: 'Unpair');
    if (!ok || !mounted) return;
    await Alerts.setEnabled(false);
    await PairingStore.clear();
    ref.read(pairingProvider.notifier).state = null;
    if (mounted) {
      Navigator.pop(context);
      context.go('/pair');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(pairingProvider);
    final conn = ref.watch(connProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(S.s5, 0, S.s5, S.s4),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(LucideIcons.laptop, size: 20, color: C.t2),
            const SizedBox(width: S.s3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p?.name ?? 'Not paired', style: T.rowTitle),
                Text(p?.host ?? '', style: T.mono12),
              ]),
            ),
            Dot(conn.online ? C.personal : C.failed),
            const SizedBox(width: 6),
            Text(conn.online ? 'connected' : 'offline', style: T.caption),
          ]),
          const SizedBox(height: S.s4),
          const Divider(height: 1),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _alerts ?? false,
            onChanged: _alerts == null || _busy ? null : _toggle,
            title: const Text('Needs-you alerts', style: T.rowTitle),
            subtitle: const Text('Stays connected in the background over Tailscale and notifies you when an agent asks something. Shows a quiet permanent notification.',
                style: T.secondary),
          ),
          const Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.refreshCw, size: 20, color: C.t2),
            title: const Text('Reconnect now', style: T.rowTitle),
            onTap: () {
              ref.read(connProvider.notifier).retry();
              Navigator.pop(context);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.unlink, size: 20, color: C.failed),
            title: Text('Unpair this phone', style: T.rowTitle.copyWith(color: C.failed)),
            onTap: _unpair,
          ),
        ]),
      ),
    );
  }
}
