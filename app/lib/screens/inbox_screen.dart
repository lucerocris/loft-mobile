import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/grouping.dart';
import '../data/loft_client.dart';
import '../data/models.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'group_sheet.dart';
import 'settings_sheet.dart';

/// Figma 2 · Inbox and 8 · Inbox · Offline.
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});
  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  bool _showDone = false;
  StreamSubscription<String>? _notices;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      ref.read(groupByProvider.notifier).state = p.getString('loft.groupBy');
      ref.read(filterProvider.notifier).state = {
        for (final d in FilterDim.values) d.name: p.getString('loft.filter.${d.name}') ?? '',
      };
    });
    _notices = ref.read(connProvider.notifier).notices.listen((m) {
      if (mounted) toast(context, m);
    });
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => mounted ? setState(() {}) : null); // ages
  }

  @override
  void dispose() {
    _notices?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  void _setFilter(FilterDim d, String v) {
    ref.read(filterProvider.notifier).state = {...ref.read(filterProvider), d.name: v};
    SharedPreferences.getInstance().then((p) => p.setString('loft.filter.${d.name}', v));
  }

  Future<void> _pickGroupBy(Snapshot snap, GroupBy current) async {
    final picked = await showGroupBySheet(context, snap, current);
    if (picked == null || !mounted) return;
    ref.read(groupByProvider.notifier).state = picked.name;
    final p = await SharedPreferences.getInstance();
    await p.setString('loft.groupBy', picked.name);
  }

  void _open(AgentCard c) {
    if (c.isTodo) {
      context.push('/todo/${c.id}');
    } else if (c.col == Col.needs) {
      context.push('/agent/${c.id}');
    } else {
      context.push('/term/${c.id}'); // a working (or finished) agent opens straight into Terminal
    }
  }

  Future<bool> _swipe(AgentCard c, DismissDirection d) async {
    final client = ref.read(clientProvider);
    if (client == null) return false;
    try {
      if (d == DismissDirection.startToEnd) {
        if (c.isTodo) return false;
        final m = await client.act(c.id, 'pin');
        if (mounted) toast(context, m);
      } else {
        if (c.col == Col.running) {
          toast(context, 'Stop it first, then archive.', error: true);
          return false;
        }
        final ok = await confirmDanger(context,
            title: c.isTodo ? 'Delete this todo?' : 'Archive this agent?',
            body: c.isTodo ? '"${c.name}" will be removed from Todo.' : '"${c.name}" leaves the inbox. Its session is kept.',
            action: c.isTodo ? 'Delete' : 'Archive');
        if (!ok) return false;
        final m = await client.act(c.id, 'archive');
        if (mounted) toast(context, m);
      }
    } on LoftError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
    return false; // the list updates from the server snapshot
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connProvider);
    final host = ref.watch(pairingProvider)?.name ?? 'fedora';
    final snap = conn.snap;
    final offline = conn.offline;
    final groupBy = effectiveGroupBy(ref.watch(groupByProvider), snap);
    final dim = filterDim(groupBy, snap);
    final options = filterOptions(snap, dim);
    var filter = ref.watch(filterProvider)[dim.name] ?? '';
    if (!options.any((o) => o.key == filter)) filter = ''; // the value is gone (deleted project, folder done)
    final groups = buildGroups(snap, groupBy, filter: filter);
    final multi = snap.multiAccount;

    Widget row(AgentCard c) {
      final acc = snap.account(c.account);
      return Dismissible(
        key: ValueKey('row-${c.id}'),
        confirmDismiss: (d) => _swipe(c, d),
        background: _swipeBg(LucideIcons.pin, c.pinned ? 'Unpin' : 'Pin', Alignment.centerLeft, C.selected),
        secondaryBackground: _swipeBg(c.isTodo ? LucideIcons.trash2 : LucideIcons.archive, c.isTodo ? 'Delete' : 'Archive', Alignment.centerRight, const Color(0xFF3A1E1B)),
        child: AgentItem(
          card: c,
          onTap: () => _open(c),
          accountColor: acc == null ? null : Color(acc.color),
          accountLabel: snap.accountLabel(c.account),
          showAccount: multi && groupBy != GroupBy.account,
          project: groupBy == GroupBy.project ? null : snap.projectOf(c),
        ),
      );
    }

    Widget header(Group g) {
      if (g.isDone) {
        return SectionHeader('Done', g.cards.length,
            trailing: g.cards.isEmpty
                ? null
                : InkWell(
                    onTap: () => setState(() => _showDone = !_showDone),
                    child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(_showDone ? 'Hide' : 'Show', style: T.label)),
                  ));
      }
      return SectionHeader(
        g.label,
        g.cards.length,
        alert: g.alert,
        needs: groupBy == GroupBy.status ? 0 : g.needs,
        lead: g.mark == Mark.none ? null : MarkDot(g.mark, g.color == null ? null : Color(g.color!)),
        trailing: groupBy == GroupBy.project && multi && g.accounts.isNotEmpty
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                for (final id in g.accounts)
                  if (snap.account(id) != null) Padding(padding: const EdgeInsets.only(left: 4), child: Dot(Color(snap.account(id)!.color), size: 6)),
              ])
            : null,
      );
    }

    final active = groups.where((g) => !g.isDone).expand((g) => g.cards);
    final list = <Widget>[
      for (final g in groups) ...[
        if (g.label.isNotEmpty) header(g),
        if (!g.isDone || _showDone) ...g.cards.map(row),
      ],
      if (conn.loaded && active.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 24, 12, 0),
          child: Column(children: [
            const LoftMark(size: 48, body: C.border, left: C.borderStrong, right: C.borderStrong),
            const SizedBox(height: 12),
            Text(filter.isEmpty ? 'Nothing needs you' : 'Nothing here right now', style: const TextStyle(fontFamily: F.sans, fontSize: 17, fontWeight: FontWeight.w600, color: C.t1)),
            const SizedBox(height: 4),
            const Text('Say what an agent should do next.', style: T.secondary),
          ]),
        ),
      if (!conn.loaded) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
    ];

    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          Column(children: [
            // App bar
            SizedBox(
              height: 64,
              child: Padding(
                padding: const EdgeInsets.only(left: S.s4, right: S.s2),
                child: Row(children: [
                  const LoftMark(size: 24),
                  const SizedBox(width: S.s2),
                  const Text('loft', style: T.appTitle),
                  const Spacer(),
                  _HostChip(name: host, offline: offline, connecting: conn.connecting && !conn.online),
                  const SizedBox(width: S.s1),
                  IconBtn(LucideIcons.ellipsisVertical, tooltip: 'More', onTap: () => showSettingsSheet(context, ref)),
                ]),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                color: C.t1,
                backgroundColor: C.raised,
                onRefresh: () => ref.read(connProvider.notifier).retry(),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(S.s4, 0, S.s4, 104),
                  children: [
                    if (offline) ...[_OfflineBanner(host: host, last: conn.lastUpdate, queued: conn.queued, unpaired: conn.unpaired, onRetry: () => ref.read(connProvider.notifier).retry()), const SizedBox(height: S.s3)],
                    InboxToolbar(groupBy: groupBy, options: options, filter: filter, onGroupBy: () => _pickGroupBy(snap, groupBy), onFilter: (v) => _setFilter(dim, v)),
                    const SizedBox(height: S.s3),
                    Opacity(opacity: offline ? .45 : 1, child: UsageStrip(snap: snap)),
                    const SizedBox(height: S.s3),
                    Opacity(opacity: offline ? .45 : 1, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: list)),
                  ],
                ),
              ),
            ),
          ]),
          // New task (FAB), centred
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(
              child: Material(
                color: C.primary,
                shape: const StadiumBorder(),
                elevation: 0,
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => context.push('/new?listen=1'),
                  onLongPress: () => context.push('/new'),
                  child: const SizedBox(
                    height: 56,
                    child: Padding(
                      padding: EdgeInsets.only(left: 20, right: 24),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(LucideIcons.mic, size: 22, color: C.onPrimary),
                        SizedBox(width: S.s2),
                        Text('New task', style: TextStyle(fontFamily: F.sans, fontSize: 16, fontWeight: FontWeight.w500, color: C.onPrimary)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _swipeBg(IconData icon, String label, Alignment align, Color color) => Container(
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(R.md)),
        alignment: align,
        padding: const EdgeInsets.symmetric(horizontal: S.s5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 18, color: C.t1), const SizedBox(width: 8), Text(label, style: T.button)]),
      );
}

class _HostChip extends StatelessWidget {
  final String name;
  final bool offline, connecting;
  const _HostChip({required this.name, required this.offline, required this.connecting});
  @override
  Widget build(BuildContext context) => Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.full)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (offline) const Dot(C.failed) else Icon(LucideIcons.laptop, size: 16, color: connecting ? C.t3 : C.t2),
          const SizedBox(width: 6),
          Text(offline ? 'offline' : name, style: TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: connecting ? C.t3 : C.t2)),
        ]),
      );
}

class _OfflineBanner extends StatelessWidget {
  final String host;
  final DateTime? last;
  final int queued;
  final bool unpaired;
  final VoidCallback onRetry;
  const _OfflineBanner({required this.host, required this.last, required this.queued, required this.unpaired, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final at = last == null ? '' : 'Last update ${TimeOfDay.fromDateTime(last!).format(context)}. ';
    final body = unpaired
        ? 'This phone was unpaired on the laptop. Open the menu and pair again.'
        : '${at}Is the laptop awake and on Tailscale? Voice falls back to phone speech; sends wait${queued > 0 ? ' ($queued waiting)' : ''}.';
    return Container(
      padding: const EdgeInsets.fromLTRB(S.s4, S.s3, S.s3, S.s3),
      decoration: BoxDecoration(color: C.raised, border: Border.all(color: C.borderStrong), borderRadius: BorderRadius.circular(R.md)),
      child: Row(children: [
        const Icon(LucideIcons.wifiOff, size: 20, color: C.t2),
        const SizedBox(width: S.s3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(unpaired ? 'Not paired any more' : 'Can\'t reach $host', style: const TextStyle(fontFamily: F.sans, fontSize: 15, fontWeight: FontWeight.w500, color: C.t1)),
            const SizedBox(height: 2),
            Text(body, style: const TextStyle(fontFamily: F.sans, fontSize: 13, height: 18 / 13, color: C.t2)),
          ]),
        ),
        const SizedBox(width: S.s3),
        if (!unpaired) Btn('Retry', onTap: onRetry, height: 40),
      ]),
    );
  }
}
