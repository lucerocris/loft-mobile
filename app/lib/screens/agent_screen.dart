import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/loft_client.dart';
import '../data/models.dart';
import '../data/outbox.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../voice/voice_controller.dart';
import '../widgets/agent_menu.dart';
import '../widgets/common.dart';
import '../widgets/voice_dock.dart';

/// Quick replies, the same three as desktop Loft. One tap sends.
const quickReplies = [
  ('Yes, go ahead', 'Yes, go ahead.'),
  ('No, stop there', 'No — stop there and wait.'),
  ('Explain more', 'Explain that in more detail first.'),
];

/// Figma 3 · It's asking (and 4 · Listening, via the Voice dock).
class AgentScreen extends ConsumerStatefulWidget {
  final String id;
  const AgentScreen({super.key, required this.id});
  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  late final VoiceController _voice;
  List<String>? _peek;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _voice = VoiceController(client: () => ref.read(clientProvider), laptopReachable: () => ref.read(connProvider).online);
    _loadPeek();
  }

  @override
  void dispose() {
    _voice.dispose();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadPeek() async {
    final c = ref.read(clientProvider);
    final card = ref.read(connProvider).snap.byId(widget.id);
    if (c == null) return;
    try {
      final tl = await c.timeline(widget.id);
      final seen = <String>{card?.detail ?? ''};
      final lines = <String>[];
      for (final e in tl.reversed) {
        final d = e.detail.trim();
        if (d.isEmpty || seen.contains(d)) continue;
        seen.add(d);
        lines.add(d);
        if (lines.length >= 3) break;
      }
      if (mounted) setState(() => _peek = lines.reversed.toList());
    } catch (_) {
      if (mounted) setState(() => _peek = const []);
    }
  }

  Future<void> _send([String? text]) async {
    final card = ref.read(connProvider).snap.byId(widget.id);
    final t = (text ?? _field.text).trim();
    if (card == null || t.isEmpty || _sending) return;
    final conn = ref.read(connProvider);
    if (!conn.online) {
      await ref.read(connProvider.notifier).enqueue(OutboxItem('reply', {'id': card.id, 'text': t}));
      _field.clear();
      if (mounted) toast(context, 'Waiting to send: ${ref.read(pairingProvider)?.name ?? 'the laptop'} is offline');
      return;
    }
    setState(() => _sending = true);
    _field.clear();
    toast(context, 'Sending to ${card.name}…');
    try {
      await ref.read(clientProvider)!.reply(card.id, t);
      if (!mounted) return;
      toast(context, 'Sent to ${card.name}');
      final next = ref.read(connProvider).snap.section(Col.needs, ref.read(filterProvider)).where((c) => c.id != card.id).firstOrNull;
      if (next != null) {
        context.pushReplacement('/agent/${next.id}');
      } else {
        context.pop();
      }
    } on LoftError catch (e) {
      if (!mounted) return;
      _field.text = t; // put it back
      toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connProvider);
    final card = conn.snap.byId(widget.id);
    final host = ref.watch(pairingProvider)?.name ?? 'fedora';
    if (card == null) {
      return Scaffold(
        appBar: AppBar(backgroundColor: C.canvas),
        body: Center(child: Text(conn.loaded ? 'That agent is gone (archived or finished elsewhere).' : 'Loading…', style: T.secondary)),
      );
    }
    final ask = splitAsk(card.detail.isEmpty ? 'It stopped and is waiting for you.' : card.detail);
    final asking = card.col == Col.needs;
    final status = card.failed ? 'Failed' : switch (card.col) { Col.needs => 'It\'s asking', Col.running => 'Working', Col.todo => 'Todo', Col.done => 'Done' };

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.all(S.s1),
              child: Row(children: [
                IconBtn(LucideIcons.arrowLeft, tooltip: 'Back', onTap: () => context.pop()),
                const SizedBox(width: S.s1),
                Expanded(child: AgentTitle(card: card)),
                IconBtn(LucideIcons.squareTerminal, tooltip: 'Open terminal', onTap: () => context.pushReplacement('/term/${card.id}')),
                SizedBox(width: 48, height: 48, child: AgentMenuButton(card: card)),
              ]),
            ),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, S.s2, 20, S.s4), children: [
              Row(children: [
                Dot(asking ? C.needs : (card.failed ? C.failed : C.account(card.work))),
                const SizedBox(width: S.s2),
                Text(status, style: TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: asking ? C.needs : C.t2)),
              ]),
              const SizedBox(height: S.s4),
              if (ask.body.isNotEmpty) SelectableText(ask.body, style: T.body),
              if (ask.body.isNotEmpty && ask.question.isNotEmpty) const SizedBox(height: S.s4),
              if (ask.question.isNotEmpty) SelectableText(ask.question, style: T.question),
              const SizedBox(height: S.s4),
              if (asking)
                Wrap(spacing: S.s2, runSpacing: S.s2, children: [
                  for (final (label, text) in quickReplies)
                    Material(
                      color: C.raised,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md), side: const BorderSide(color: C.borderStrong)),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(R.md),
                        onTap: _sending ? null : () => _send(text),
                        child: SizedBox(height: 44, child: Padding(padding: const EdgeInsets.symmetric(horizontal: S.s4), child: Center(widthFactor: 1, child: Text(label, style: T.button)))),
                      ),
                    ),
                ]),
              const SizedBox(height: S.s4),
              _LastOutput(lines: _peek, onOpen: () => context.pushReplacement('/term/${card.id}')),
            ]),
          ),
          VoiceDock(
            voice: _voice,
            field: _field,
            focus: _focus,
            hostName: host,
            laptopReachable: conn.online,
            onSend: _send,
            onTranscript: (t) async => deliverTranscript(context, _field, t, go: _send, goLabel: 'Sending to ${card.name}'),
          ),
        ]),
      ),
    );
  }
}

class _LastOutput extends StatelessWidget {
  final List<String>? lines;
  final VoidCallback onOpen;
  const _LastOutput({required this.lines, required this.onOpen});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(S.s4, S.s3, S.s4, S.s4),
        decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(LucideIcons.squareTerminal, size: 16, color: C.t3),
            const SizedBox(width: S.s2),
            const Expanded(child: Text('Last output', style: TextStyle(fontFamily: F.sans, fontSize: 12, fontWeight: FontWeight.w500, color: C.t3))),
            InkWell(
              onTap: onOpen,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                child: Text('Open terminal', style: TextStyle(fontFamily: F.sans, fontSize: 12, fontWeight: FontWeight.w500, color: C.t2)),
              ),
            ),
          ]),
          const SizedBox(height: S.s2),
          if (lines == null)
            const Text('…', style: TextStyle(fontFamily: F.mono, fontSize: 12, height: 19 / 12, color: C.t2))
          else if (lines!.isEmpty)
            const Text('No earlier output.', style: TextStyle(fontFamily: F.mono, fontSize: 12, height: 19 / 12, color: C.t2))
          else
            for (final l in lines!)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('● $l', style: const TextStyle(fontFamily: F.mono, fontSize: 12, height: 19 / 12, color: C.t2)),
              ),
        ]),
      );
}
