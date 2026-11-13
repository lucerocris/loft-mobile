import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/chat.dart';
import '../data/loft_client.dart';
import '../data/models.dart';
import '../data/outbox.dart';
import '../state/conn.dart';
import '../state/session_view.dart';
import '../theme/tokens.dart';
import '../voice/voice_controller.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/common.dart';
import '../widgets/prompt_actions.dart';
import '../widgets/session_header.dart';
import '../widgets/voice_dock.dart';

/// Figma "Chat view · Mobile": the agent's session as a readable chat.
/// Polls `/messages?after=<cursor>` while open; the Chat | Terminal toggle
/// switches to the live terminal and is remembered.
class ChatScreen extends ConsumerStatefulWidget {
  final String id;
  /// Poll interval (tests shorten it).
  final Duration every;
  const ChatScreen({super.key, required this.id, this.every = const Duration(seconds: 2)});
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> with PromptActions {
  final _log = ChatLog();
  final _field = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late final VoiceController _voice;
  ChatPage? _page;
  PickerState? _picker;
  int? _otherFor; // the picker question whose "Other" answer the reply bar is taking
  bool _loading = true, _olderBusy = false, _polling = false, _sending = false;
  LoftError? _error;
  DateTime? _fetchedAt;
  Timer? _timer;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _voice = VoiceController(client: () => ref.read(clientProvider), laptopReachable: () => ref.read(connProvider).online);
    _load();
    _timer = Timer.periodic(widget.every, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _voice.dispose();
    _field.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Future<void> reloadPrompt() => _poll(force: true);

  Future<void> _load() async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    setState(() {
      _loading = !_log.loaded;
      _error = null;
    });
    try {
      final p = await c.messages(widget.id);
      if (!mounted) return;
      setState(() {
        _log.apply(p);
        _took(p);
      });
    } on LoftError catch (e) {
      if (!mounted) return;
      if (e.status == 404 && ref.read(connProvider).snap.byId(widget.id) != null) return _unsupported();
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _took(ChatPage p) {
    _page = p;
    _fetchedAt = DateTime.now();
    _error = null;
    final pr = p.prompt;
    if (pr == null || pr.kind != PromptKind.question || pr.questions.isEmpty) {
      _picker = null;
      if (pr == null) _otherFor = null;
    } else if (_picker?.prompt.tool != pr.tool) {
      _picker = PickerState(pr);
      _otherFor = null;
    }
  }

  Future<void> _poll({bool force = false}) async {
    final c = ref.read(clientProvider);
    if (c == null || _polling || !mounted || (!_log.loaded && !force)) {
      if (!_log.loaded && !_loading && c != null && _error != null) _load(); // retry after an error
      return;
    }
    final card = ref.read(connProvider).snap.byId(widget.id);
    _tick++;
    final quiet = card == null || card.col == Col.done || card.col == Col.todo;
    if (!force && quiet && _tick % 3 != 0) return; // finished: check every 6 s
    _polling = true;
    try {
      final p = await c.messages(widget.id, after: _log.cursor, session: _log.session);
      if (!mounted) return;
      setState(() {
        _log.apply(p);
        _took(p);
      });
    } on LoftError catch (e) {
      if (mounted && !e.offline) setState(() => _error = e);
    } finally {
      _polling = false;
    }
  }

  Future<void> _older() async {
    final c = ref.read(clientProvider);
    if (c == null || _olderBusy || !_log.more) return;
    setState(() => _olderBusy = true);
    try {
      final p = await c.messages(widget.id, before: _log.start);
      if (mounted) setState(() => _log.apply(p, older: true));
    } on LoftError catch (_) {
    } finally {
      if (mounted) setState(() => _olderBusy = false);
    }
  }

  /// An older Loft on the laptop: no chat API. Say so once and show what works.
  void _unsupported() {
    ref.read(chatUnsupportedProvider.notifier).state = true;
    final card = ref.read(connProvider).snap.byId(widget.id);
    final needs = card?.col == Col.needs;
    toast(context, 'Chat needs a newer Loft on the laptop. Showing ${needs ? 'the question' : 'Terminal'} instead.');
    context.pushReplacement(needs ? '/ask/${widget.id}' : '/term/${widget.id}');
  }

  // ---------------------------------------------------------------- sending
  Future<void> _send([String? text]) async {
    final card = ref.read(connProvider).snap.byId(widget.id);
    final t = (text ?? _field.text).trim();
    if (card == null || t.isEmpty || _sending) return;
    final s = _picker;
    // Typed while a picker is open: it is that question's "Other" answer.
    if (s != null && (_otherFor != null || text == null)) {
      final i = _otherFor ?? s.step;
      _field.clear();
      setState(() {
        s.setOther(i, t);
        _otherFor = null;
        if (!s.qs[i].multi && s.step == i) {
          if (!s.isLast) {
            s.step++;
          }
        }
      });
      if (!s.qs[i].multi && s.isLast && s.complete) await answerQuestion(card.id, s);
      return;
    }
    final pr = _page?.prompt;
    if (pr != null && pr.kind == PromptKind.permission && text == null && pr.options.isNotEmpty) {
      // A reply to a permission prompt: say No to it (Enter would say Yes), then send the words.
      final (n, label) = pr.options.last;
      _field.clear();
      await answerPermission(card.id, pr, n, label, thenReply: t);
      return;
    }
    final conn = ref.read(connProvider);
    if (!conn.online) {
      await ref.read(connProvider.notifier).enqueue(OutboxItem('reply', {'id': card.id, 'text': t}));
      _field.clear();
      if (mounted) toast(context, 'Waiting to send: ${ref.read(pairingProvider)?.name ?? 'the laptop'} is offline');
      return;
    }
    setState(() => _sending = true);
    _field.clear();
    try {
      await ref.read(clientProvider)!.reply(card.id, t);
      if (!mounted) return;
      setState(() => _log.addLocal(t));
      _poll(force: true);
    } on LoftError catch (e) {
      if (!mounted) return;
      _field.text = t;
      toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _other(PickerState s, int i) {
    setState(() {
      _otherFor = i;
      _field.text = s.other[i] ?? '';
    });
    _focus.requestFocus();
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connProvider);
    final card = conn.snap.byId(widget.id);
    final host = ref.watch(pairingProvider)?.name ?? 'the laptop';
    ref.listen(connProvider.select((c) => (c.snap.byId(widget.id)?.updated, c.snap.byId(widget.id)?.col)), (a, b) {
      if (a != b) _poll(force: true);
    });
    if (card == null) {
      return Scaffold(
        appBar: AppBar(backgroundColor: C.canvas),
        body: Center(child: Text(conn.loaded ? 'That agent is gone (archived or finished elsewhere).' : 'Loading…', style: T.secondary)),
      );
    }
    final otherQ = _otherFor != null && _picker != null ? _picker!.qs[_otherFor!].question : null;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SessionHeader(card: card, mode: SessionView.chat),
          Expanded(child: _body(card, conn, host)),
          VoiceDock(
            compact: true,
            voice: _voice,
            field: _field,
            focus: _focus,
            hostName: host,
            laptopReachable: conn.online,
            placeholder: otherQ != null
                ? 'Your answer'
                : switch (card.col) {
                    Col.done => 'Send a follow-up',
                    Col.todo => 'Tell it what to do',
                    _ => 'Reply, or hold the mic',
                  },
            chip: otherQ == null ? null : 'Other answer for “$otherQ”',
            onChipCancel: () => setState(() {
              _otherFor = null;
              _field.clear();
            }),
            banner: conn.online || !conn.loaded ? null : 'Replies wait on the phone and send when $host is back',
            onSend: _send,
            onTranscript: (t) async => deliverTranscript(context, _field, t, go: _send, goLabel: otherQ != null ? 'Answering' : 'Sending to ${card.name}'),
          ),
        ]),
      ),
    );
  }

  Widget _body(AgentCard card, Conn conn, String host) {
    final banners = <Widget>[
      if (!conn.online && conn.loaded && !conn.connecting)
        ChatBanner(
          icon: LucideIcons.wifiOff,
          title: '$host is offline',
          text: _fetchedAt == null ? 'Nothing loaded yet.' : 'Showing messages from ${ago(_fetchedAt)} ago.',
          action: 'Retry',
          onAction: () => ref.read(connProvider.notifier).retry().then((_) => _load()),
        )
      else if (_error != null && !_error!.offline)
        ChatBanner(icon: LucideIcons.triangleAlert, color: C.failed, title: 'Couldn\'t load the chat', text: _error!.message, action: 'Retry', onAction: _load),
    ];
    if (_loading && !_log.loaded) return Column(children: [...banners.map(_pad), const Expanded(child: _Skeleton())]);
    final rows = _log.rows();
    final asking = card.col == Col.needs;
    final empty = _log.loaded && rows.isEmpty && !asking;
    if (empty || (!_log.loaded && _error != null)) {
      return Column(children: [
        ...banners.map(_pad),
        Expanded(child: _Empty(card: card, failed: !_log.loaded)),
      ]);
    }
    final pending = _page?.prompt;
    final open = _log.openTool;
    final lastText = _log.items.lastWhere((i) => i.kind == ChatKind.assistant, orElse: () => const ChatItem(id: '', kind: ChatKind.unknown)).text;
    final ask = splitAsk(card.detail);
    // Newest first (the list is reversed so it sticks to the bottom).
    final entries = <Widget>[
      if (asking)
        PickerCard(
          key: ValueKey('picker:${pending?.tool}'),
          prompt: pending,
          state: _picker,
          detail: card.detail,
          showBody: ask.body.isEmpty || !lastText.contains(ask.body.substring(0, ask.body.length.clamp(0, 40))),
          busy: answering,
          onAnswer: (s) => answerQuestion(card.id, s),
          onPermission: (n, l) => answerPermission(card.id, pending!, n, l),
          onQuickReply: (t) => _send(t),
          onOther: _other,
        ),
      if (card.col == Col.running) WorkingRow(label: open != null ? open.title : card.detail, color: _accColor(card)),
      for (final r in rows.reversed) _row(r, pending, card, open),
      if (_log.more)
        Center(
          child: _olderBusy
              ? const Padding(padding: EdgeInsets.all(S.s3), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : TextButton(onPressed: _older, child: const Text('Load earlier', style: T.label)),
        )
      else if (_log.loaded)
        const NoteRow('Start of the conversation'),
      ...banners.reversed,
    ];
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 600 && _log.more && !_olderBusy) _older();
        return false;
      },
      child: ListView.separated(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.fromLTRB(S.s4, S.s4, S.s4, S.s4),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: S.s4),
        itemBuilder: (_, i) => entries[i],
      ),
    );
  }

  Widget _pad(Widget w) => Padding(padding: const EdgeInsets.fromLTRB(S.s4, S.s4, S.s4, 0), child: w);

  Widget _row(ChatRow r, PendingPrompt? pending, AgentCard card, ChatItem? open) =>
      ChatRowView(log: _log, row: r, pending: pending, asking: card.col == Col.needs, running: card.col == Col.running, open: open);

  Color _accColor(AgentCard c) {
    final a = ref.read(connProvider).snap.account(c.account);
    return a == null ? C.work : Color(a.color);
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) {
    Widget bar(double w, [double h = 14, double r = 6]) => Container(width: w, height: h, decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(r)));
    return Semantics(
      label: 'Loading the conversation',
      child: Padding(
        padding: const EdgeInsets.all(S.s4),
        child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Align(alignment: Alignment.centerRight, child: bar(220, 44, 14)),
          const SizedBox(height: 20),
          bar(320), const SizedBox(height: 10), bar(290), const SizedBox(height: 10), bar(220),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.md)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bar(200, 12), const SizedBox(height: 20), bar(160, 12), const SizedBox(height: 20), bar(230, 12)]),
          ),
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final AgentCard card;
  final bool failed;
  const _Empty({required this.card, this.failed = false});
  @override
  Widget build(BuildContext context) {
    final todo = card.col == Col.todo;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(S.s8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(LucideIcons.messageSquare, size: 36, color: C.t3),
          const SizedBox(height: S.s3),
          Text(failed ? 'Nothing to show yet' : 'No conversation yet', style: T.screenTitle),
          const SizedBox(height: S.s2),
          Text(
            todo
                ? 'This one hasn\'t started. Once it runs, its messages, steps and questions show up here.'
                : (failed ? 'The chat didn\'t load. Terminal shows the live session.' : 'Its messages, steps and questions show up here once it says something.'),
            textAlign: TextAlign.center,
            style: T.secondary.copyWith(fontSize: 14),
          ),
          const SizedBox(height: S.s4),
          if (failed) Btn('Open terminal', icon: LucideIcons.squareTerminal, onTap: () => context.pushReplacement('/term/${card.id}')),
        ]),
      ),
    );
  }
}
