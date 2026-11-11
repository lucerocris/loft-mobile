import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/chat.dart';
import '../data/grouping.dart';
import '../data/loft_client.dart';
import '../data/models.dart';
import '../data/outbox.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../voice/voice_controller.dart';
import '../widgets/agent_menu.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/common.dart';
import '../widgets/prompt_actions.dart';
import '../widgets/voice_dock.dart';

/// Figma 3 · It's asking (and 4 · Listening, via the Voice dock). The question
/// card is the chat view's picker: real options when the laptop's Loft reads them.
class AgentScreen extends ConsumerStatefulWidget {
  final String id;
  const AgentScreen({super.key, required this.id});
  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> with PromptActions {
  final _field = TextEditingController();
  final _focus = FocusNode();
  late final VoiceController _voice;
  List<String>? _peek;
  PendingPrompt? _prompt;
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

  @override
  Future<void> reloadPrompt() => _loadPrompt();

  /// The picker it waits on (newer Loft only; an older one 404s and the plain card stays).
  Future<void> _loadPrompt() async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    try {
      final p = await c.messages(widget.id, limit: 12);
      if (mounted) setState(() => _prompt = p.prompt);
    } catch (_) {}
  }

  Future<void> _loadPeek() async {
    _loadPrompt();
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
      final snap = ref.read(connProvider).snap;
      final dim = filterDim(effectiveGroupBy(ref.read(groupByProvider), snap), snap);
      final filter = ref.read(filterProvider)[dim.name] ?? '';
      final next = (snap.cards.where((c) => c.col == Col.needs && c.id != card.id && matchesFilter(snap, c, dim, filter)).toList()..sort(byPinThenNewest)).firstOrNull;
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
                Dot(asking ? C.needs : (card.failed ? C.failed : _accColor(ref, card))),
                const SizedBox(width: S.s2),
                Text(status, style: TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: asking ? C.needs : C.t2)),
              ]),
              const SizedBox(height: S.s4),
              if (asking)
                PickerCard(
                  key: ValueKey('picker:${_prompt?.tool}'),
                  prompt: _prompt,
                  detail: card.detail,
                  busy: _sending || answering,
                  onAnswer: (s) => answerQuestion(card.id, s),
                  onPermission: (n, l) => answerPermission(card.id, _prompt!, n, l),
                  onQuickReply: (t) => _send(t),
                  onOther: (s, i) => _focus.requestFocus(),
                )
              else ...[
                if (ask.body.isNotEmpty) SelectableText(ask.body, style: T.body),
                if (ask.body.isNotEmpty && ask.question.isNotEmpty) const SizedBox(height: S.s4),
                if (ask.question.isNotEmpty) SelectableText(ask.question, style: T.question),
              ],
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

Color _accColor(WidgetRef ref, AgentCard c) {
  final a = ref.watch(connProvider).snap.account(c.account);
  return a == null ? C.t2 : Color(a.color);
}
