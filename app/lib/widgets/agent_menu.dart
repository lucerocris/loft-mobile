import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/grouping.dart';
import '../data/loft_client.dart';
import '../data/models.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../screens/group_sheet.dart';
import 'common.dart';

/// App-bar title for an agent: name, then account dot · Work · project · age.
/// (Account only with more than one; project only when it has one.)
class AgentTitle extends ConsumerWidget {
  final AgentCard card;
  final String? status;
  const AgentTitle({super.key, required this.card, this.status});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = card;
    final snap = ref.watch(connProvider).snap;
    final acc = snap.account(c.account);
    final proj = snap.projectOf(c);
    const sep = Text(' · ', style: TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3));
    final parts = <Widget>[
      if (snap.multiAccount)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Dot(acc == null ? C.t3 : Color(acc.color), size: 6, hollow: acc == null),
          const SizedBox(width: 6),
          Text(snap.accountLabel(c.account), style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t2)),
          if (c.pendingAccount != null && c.pendingAccount != c.account)
            Text(' → ${snap.accountLabel(c.pendingAccount)} next turn', style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.needs)),
        ]),
      if (proj != null)
        Flexible(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            MarkDot(Mark.square, Color(proj.color), size: 6),
            const SizedBox(width: 6),
            Flexible(child: Text(proj.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t2))),
          ]),
        ),
      if (status != null)
        Flexible(child: Text(status!, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3)))
      else ...[
        if (proj == null) Flexible(child: Text(c.folderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono12)),
        Text(ago(c.updated), style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3)),
      ],
    ];
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.screenTitle),
      const SizedBox(height: 4),
      Row(children: [
        for (final (i, w) in parts.indexed) ...[if (i > 0) sep, w],
      ]),
    ]);
  }
}

/// The ⋮ menu for an agent: pin, rename, move account, stop (confirm), archive (confirm).
class AgentMenuButton extends ConsumerWidget {
  final AgentCard card;
  const AgentMenuButton({super.key, required this.card});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = card;
    final running = c.col == Col.running;
    final snap = ref.watch(connProvider).snap;
    final others = snap.accounts.where((a) => a.id != c.account).toList();
    PopupMenuItem<String> item(String v, IconData i, String label, {bool enabled = true, Color? color}) => PopupMenuItem(
          value: v,
          enabled: enabled,
          height: 48,
          child: Row(children: [
            Icon(i, size: 18, color: enabled ? (color ?? C.t2) : C.t3),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontFamily: F.sans, fontSize: 15, color: enabled ? (color ?? C.t1) : C.t3)),
          ]),
        );
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(LucideIcons.ellipsisVertical, size: 22, color: C.t1),
      itemBuilder: (_) => [
        if (c.hasBrowser) item('browser', LucideIcons.appWindow, 'Open its browser'),
        if (!c.isTodo) item('pin', c.pinned ? LucideIcons.pinOff : LucideIcons.pin, c.pinned ? 'Unpin' : 'Pin to top'),
        item('rename', LucideIcons.pencil, 'Rename'),
        if (snap.supportsProjects) item('project', LucideIcons.folderInput, 'Move to project…'),
        if (others.length == 1) item('account', LucideIcons.arrowLeftRight, running ? 'Move to ${others.single.label} after this turn' : 'Move to ${others.single.label}'),
        if (others.length > 1) item('account', LucideIcons.arrowLeftRight, running ? 'Move to account after this turn…' : 'Move to account…'),
        if (running) item('stop', LucideIcons.square, 'Stop', color: C.failed),
        item('archive', c.isTodo ? LucideIcons.trash2 : LucideIcons.archive, c.isTodo ? 'Delete' : 'Archive', enabled: !running, color: C.failed),
      ],
      onSelected: (a) => runAgentAction(context, ref, c, a),
    );
  }
}

Future<void> runAgentAction(BuildContext context, WidgetRef ref, AgentCard c, String a) async {
  if (a == 'browser') {
    context.push('/browser/agent/${c.id}');
    return;
  }
  final client = ref.read(clientProvider);
  if (client == null) return;
  Map<String, dynamic> body = const {};
  if (a == 'stop' &&
      !await confirmDanger(context, title: 'Stop this agent?', body: '"${c.name}" stops working now. You can reply later to pick it up again.', action: 'Stop')) {
    return;
  }
  if (!context.mounted) return;
  if (a == 'archive' &&
      !await confirmDanger(context,
          title: c.isTodo ? 'Delete this todo?' : 'Archive this agent?',
          body: c.isTodo ? '"${c.name}" will be removed from Todo.' : '"${c.name}" leaves the inbox. Its session is kept.',
          action: c.isTodo ? 'Delete' : 'Archive')) {
    return;
  }
  if (!context.mounted) return;
  final snap = ref.read(connProvider).snap;
  if (a == 'project') {
    final pick = await showMoveToProjectSheet(context, snap, c);
    if (pick == null || !context.mounted) return;
    if (pick == newProjectPick) {
      context.push('/projects?new=1&card=${c.id}');
      return;
    }
    try {
      final m = await client.setCardProject(c.id, pick == unsortedKey ? null : pick);
      if (context.mounted) toast(context, m.isEmpty || m == 'null' ? 'Moved' : m);
    } on LoftError catch (e) {
      if (context.mounted) toast(context, e.message, error: true);
    }
    return;
  }
  if (a == 'account') {
    final others = snap.accounts.where((x) => x.id != c.account).toList();
    final String? to = others.length == 1 ? others.single.id : await showMoveToAccountSheet(context, snap, c);
    if (to == null || to == c.account || !context.mounted) return;
    body = {'account': to};
  }
  if (a == 'rename') {
    final ctl = TextEditingController(text: c.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: ctl, autofocus: true, style: T.body, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          Btn('Cancel', onTap: () => Navigator.pop(ctx), kind: BtnKind.quiet, height: 44),
          Btn('Save', onTap: () => Navigator.pop(ctx, ctl.text), kind: BtnKind.primary, height: 44),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == c.name) return;
    body = {'name': name.trim()};
  }
  try {
    final m = await client.act(c.id, a, body);
    if (!context.mounted) return;
    toast(context, m);
    if (a == 'archive') context.go('/');
  } on LoftError catch (e) {
    if (context.mounted) toast(context, e.message, error: true);
  }
}
