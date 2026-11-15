import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../state/conn.dart';
import '../state/session_view.dart';
import '../theme/tokens.dart';
import 'agent_menu.dart';
import 'common.dart';

/// Figma "Chat view · Mobile": back, name, account · folder · age, ⋮; then the
/// Chat | Terminal toggle and the status on the right.
class SessionHeader extends ConsumerWidget {
  final AgentCard card;
  final SessionView mode;
  /// Overrides the status text (the terminal shows "attached · live").
  final String? status;
  final bool showMenu;
  const SessionHeader({super.key, required this.card, required this.mode, this.status, this.showMenu = true});

  static (String, Color, bool) statusOf(AgentCard c, Color accColor) {
    if (c.failed) return ('Failed', C.failed, false);
    return switch (c.col) {
      Col.needs => ('Needs you', C.needs, false),
      Col.running => ('Working', accColor, false),
      Col.todo => ('Todo', C.t3, true),
      Col.done => ('Done', C.t3, false),
    };
  }

  void _switch(BuildContext context, SessionView v) {
    if (v == mode) return;
    context.pushReplacement(v == SessionView.chat ? '/chat/${card.id}' : '/term/${card.id}');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(connProvider).snap;
    final acc = snap.account(card.account);
    final accColor = acc == null ? C.t2 : Color(acc.color);
    final (label, color, hollow) = statusOf(card, accColor);
    final sub = <Widget>[
      if (snap.accounts.isNotEmpty) ...[
        Dot(acc == null ? C.t3 : accColor, size: 6, hollow: acc == null),
        const SizedBox(width: 6),
        Flexible(child: Text(snap.accountLabel(card.account), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t2))),
        Text(' · ', style: TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3)),
      ],
      Flexible(child: Text(card.folderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono12)),
      Text(' · ', style: TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3)),
      Text(ago(card.updated), style: TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3)),
    ];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.all(S.s1),
        child: Row(children: [
          IconBtn(LucideIcons.arrowLeft, tooltip: mode == SessionView.terminal ? 'Back (detaches)' : 'Back', glass: true, onTap: () => context.pop()),
          const SizedBox(width: S.s1),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(card.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.screenTitle),
              const SizedBox(height: 4),
              Row(children: sub),
            ]),
          ),
          if (showMenu && card.isAgent) Padding(padding: const EdgeInsets.all(4), child: Glass(child: SizedBox(width: 40, height: 40, child: AgentMenuButton(card: card)))) else const SizedBox(width: 48),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(S.s4, 2, S.s4, 10),
        child: Row(children: [
          ViewToggle(mode: mode, onChanged: (v) => _switch(context, v)),
          const SizedBox(width: S.s3),
          Expanded(
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              Dot(status != null ? accColor : color, hollow: hollow && status == null),
              const SizedBox(width: S.s2),
              Flexible(
                child: Text(status ?? label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: status == null && color == C.needs ? C.needs : C.t2)),
              ),
            ]),
          ),
        ]),
      ),
    ]);
  }
}

/// The Chat | Terminal segmented control (Material-like, Loft's styling).
class ViewToggle extends StatelessWidget {
  final SessionView mode;
  final ValueChanged<SessionView> onChanged;
  const ViewToggle({super.key, required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) => Glass(
        child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _seg(SessionView.chat, 'Chat', LucideIcons.messageSquare),
          const SizedBox(width: 2),
          _seg(SessionView.terminal, 'Terminal', LucideIcons.squareTerminal),
        ]),
      ));

  Widget _seg(SessionView v, String label, IconData icon) {
    final on = v == mode;
    return Semantics(
      button: true,
      selected: on,
      label: 'Show $label',
      excludeSemantics: true,
      child: Material(
        color: on ? C.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(R.full),
        child: InkWell(
          borderRadius: BorderRadius.circular(R.full),
          onTap: () => onChanged(v),
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 14, 0),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 16, color: on ? C.t1 : C.t3),
                const SizedBox(width: 6),
                Text(label, style: TextStyle(fontFamily: F.sans, fontSize: 14, fontWeight: FontWeight.w500, color: on ? C.t1 : C.t2)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
