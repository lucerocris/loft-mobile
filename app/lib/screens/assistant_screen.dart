import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/chat.dart';
import '../data/loft_client.dart';
import '../data/models.dart';
import '../state/assistant.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../voice/voice_controller.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/common.dart';
import '../widgets/prompt_actions.dart';
import '../widgets/voice_dock.dart';

/// What the empty assistant offers. [send] = sent as is; otherwise it fills
/// the field (and starts listening) for the rest.
class AssistantSuggestion {
  final String label, text;
  final IconData icon;
  final bool send;
  const AssistantSuggestion(this.label, this.icon, {String? text, this.send = true}) : text = text ?? label;
}

const assistantSuggestions = [
  AssistantSuggestion('Archive everything that\'s done', LucideIcons.archive),
  AssistantSuggestion('Stop all running agents', LucideIcons.square),
  AssistantSuggestion('What needs me?', LucideIcons.bellRing),
  AssistantSuggestion('Start a task…', LucideIcons.plus, text: 'Start a task: ', send: false),
];

/// The Loft Assistant: one long-lived session whose only job is operating Loft
/// (start, stop, archive, find, summarize). Voice first; the transcript is the
/// chat view's (GET `/api/cards/<id>/messages`, pickers via `/answer`).
class AssistantScreen extends ConsumerStatefulWidget {
  /// Start listening straight away (long-press on the inbox button).
  final bool listen;
  final Duration every;
  const AssistantScreen({super.key, this.listen = false, this.every = const Duration(seconds: 2)});
  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> with PromptActions {
  var _log = ChatLog();
  final _field = TextEditingController();
  final _focus = FocusNode();
  late final VoiceController _voice;
  Timer? _timer;
  int _tick = 0;

  /// The assistant's card id; null before the first message (or after a reset).
  String? _id;
  AgentCard? _infoCard;
  bool _booting = true, _unsupported = false, _sending = false, _polling = false, _resetting = false;
  /// Sent, and the assistant hasn't said anything back yet.
  bool _waiting = false;
  LoftError? _error;
  ChatPage? _page;
  PickerState? _picker;
  int? _otherFor;

  @override
  void initState() {
    super.initState();
    _voice = VoiceController(client: () => ref.read(clientProvider), laptopReachable: () => ref.read(connProvider).online);
    _boot();
    _timer = Timer.periodic(widget.every, (_) => _poll());
    if (widget.listen) WidgetsBinding.instance.addPostFrameCallback((_) => _voice.start());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _voice.dispose();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Future<void> reloadPrompt() => _poll(force: true);

  Future<void> _boot() async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    setState(() {
      _booting = true;
      _error = null;
    });
    try {
      final info = await c.assistant();
      if (!mounted) return;
      if (info == null) {
        setState(() => _unsupported = true);
        return;
      }
      ref.read(assistantSupportProvider.notifier).seen();
      setState(() {
        _adopt(info.id);
        _infoCard = info.card;
      });
      if (_id != null) await _poll(force: true);
    } on LoftError catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _booting = false);
    }
  }

  /// A new assistant session (first message, reset, or reset elsewhere): start the log over.
  void _adopt(String? id) {
    if (id == _id) return;
    _id = id;
    _log = ChatLog();
    _page = null;
    _picker = null;
    _otherFor = null;
  }

  AgentCard? _card(Snapshot snap) {
    final a = snap.assistant;
    if (a != null && a.id == _id) return a;
    return _infoCard?.id == _id ? _infoCard : null;
  }

  Future<void> _poll({bool force = false}) async {
    final c = ref.read(clientProvider);
    final id = _id;
    if (c == null || id == null || _polling || !mounted) return;
    final card = _card(ref.read(connProvider).snap);
    final quiet = !_waiting && (card == null || card.col == Col.done);
    _tick++;
    if (!force && quiet && _tick % 3 != 0) return; // idle: check every few polls
    _polling = true;
    try {
      final p = await c.messages(id, after: _log.loaded ? _log.cursor : null, session: _log.loaded ? _log.session : null);
      if (!mounted || id != _id) return;
      setState(() {
        final before = _log.items.length;
        _log.apply(p);
        _took(p);
        // The assistant answered (anything after our message), or it is asking.
        if (_waiting && (p.state == 'needs' || _log.items.skip(before).any((i) => i.kind != ChatKind.user))) _waiting = false;
      });
    } on LoftError catch (e) {
      if (!mounted) return;
      if (e.status == 404) {
        // Reset or archived elsewhere: ask Loft which session is current.
        final info = await c.assistant().catchError((_) => null);
        if (mounted && info != null) setState(() => _adopt(info.id));
      } else if (!e.offline) {
        setState(() => _error = e);
      }
    } finally {
      _polling = false;
    }
  }

  void _took(ChatPage p) {
    _page = p;
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

  // ---------------------------------------------------------------- sending
  Future<void> _send([String? text]) async {
    final t = (text ?? _field.text).trim();
    if (t.isEmpty || _sending) return;
    final card = _card(ref.read(connProvider).snap);
    final s = _picker;
    // Typed while its picker is open: that question's "Other" answer.
    if (card != null && card.col == Col.needs && s != null && (_otherFor != null || text == null)) {
      final i = _otherFor ?? s.step;
      _field.clear();
      setState(() {
        s.setOther(i, t);
        _otherFor = null;
        if (!s.qs[i].multi && s.step == i && !s.isLast) s.step++;
      });
      if (!s.qs[i].multi && s.isLast && s.complete) await answerQuestion(card.id, s);
      return;
    }
    final pr = _page?.prompt;
    if (card != null && card.col == Col.needs && pr != null && pr.kind == PromptKind.permission && text == null && pr.options.isNotEmpty) {
      final (n, label) = pr.options.last;
      _field.clear();
      await answerPermission(card.id, pr, n, label, thenReply: t);
      return;
    }
    if (!ref.read(connProvider).online) {
      toast(context, '${ref.read(pairingProvider)?.name ?? 'The laptop'} is offline. The assistant runs there, so try again when it\'s back.', error: true);
      return;
    }
    setState(() => _sending = true);
    _field.clear();
    try {
      final id = await ref.read(clientProvider)!.askAssistant(t);
      if (!mounted) return;
      setState(() {
        if (id.isNotEmpty) _adopt(id);
        _log.addLocal(t);
        _waiting = true;
      });
      await _poll(force: true);
    } on LoftError catch (e) {
      if (!mounted) return;
      _field.text = t;
      toast(context, e.status == 404 ? 'The Loft Assistant needs a newer Loft on the laptop.' : e.message, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _suggest(AssistantSuggestion s) {
    if (s.send) {
      _send(s.text);
      return;
    }
    _field.text = s.text;
    _field.selection = TextSelection.collapsed(offset: _field.text.length);
    _voice.start();
  }

  Future<void> _reset() async {
    final c = ref.read(clientProvider);
    if (c == null || _resetting) return;
    if (_id == null) {
      toast(context, 'This is already a new conversation');
      return;
    }
    setState(() => _resetting = true);
    try {
      final m = await c.resetAssistant();
      if (!mounted) return;
      setState(() {
        _adopt(null);
        _infoCard = null;
        _waiting = false;
      });
      toast(context, m.isEmpty || m == 'null' ? 'New conversation' : m);
    } on LoftError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _resetting = false);
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
    final host = ref.watch(pairingProvider)?.name ?? 'the laptop';
    ref.listen(connProvider.select((c) => (c.snap.assistant?.id, c.snap.assistant?.updated, c.snap.assistant?.col)), (a, b) {
      if (a == b) return;
      final id = b.$1;
      // Loft started a new session (reset on the laptop, or our first message raced the poll).
      if (id != null && id != _id && !_resetting && !_sending) setState(() => _adopt(id));
      _poll(force: true);
    });
    final card = _card(conn.snap);
    final empty = _id == null || (_log.loaded && _log.items.isEmpty && card?.col != Col.needs);
    final otherQ = _otherFor != null && _picker != null ? _picker!.qs[_otherFor!].question : null;
    final working = _waiting || card?.col == Col.running;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          _header(card, conn, working),
          Expanded(child: _body(card, conn, host, empty, working)),
          if (empty && !_waiting && !_unsupported) _chips(),
          if (!_unsupported)
            _Composer(
              voice: _voice,
              field: _field,
              focus: _focus,
              hostName: host,
              laptopReachable: conn.online,
              placeholder: otherQ != null ? 'Your answer' : 'Ask Loft to do something',
              chip: otherQ == null ? null : 'Other answer for “$otherQ”',
              onChipCancel: () => setState(() {
                _otherFor = null;
                _field.clear();
              }),
              banner: conn.online || !conn.loaded ? null : '$host is offline. The assistant runs there.',
              onSend: _send,
              onTranscript: (t) async => deliverTranscript(context, _field, t, go: _send, goLabel: otherQ != null ? 'Answering' : 'Asking Loft', always: true),
            ),
        ]),
      ),
    );
  }

  Widget _header(AgentCard? card, Conn conn, bool working) {
    final acc = conn.snap.account(card?.account);
    final (label, color) = card == null
        ? (_id == null ? 'New conversation' : 'Ready', C.t3)
        : card.col == Col.needs
            ? ('Needs you', C.needs)
            : working
                ? ('Working', acc == null ? C.work : Color(acc.color))
                : ('Ready', C.t3);
    return Padding(
      padding: const EdgeInsets.all(S.s1),
      child: Row(children: [
        IconBtn(LucideIcons.arrowLeft, tooltip: 'Back', onTap: () => context.canPop() ? context.pop() : context.go('/')),
        const SizedBox(width: S.s1),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Loft Assistant', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.screenTitle),
            const SizedBox(height: 4),
            Row(children: [
              if (working && card?.col != Col.needs) Pulse(color: color) else Dot(color, size: 6),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontFamily: F.sans, fontSize: 13, color: color == C.needs ? C.needs : C.t2)),
              if (conn.snap.multiAccount && acc != null) ...[
                const Text(' · ', style: TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3)),
                Flexible(child: Text(acc.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t2))),
              ],
            ]),
          ]),
        ),
        if (_resetting)
          const SizedBox(width: 48, height: 48, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))))
        else
          IconBtn(LucideIcons.squarePen, tooltip: 'New conversation', onTap: _unsupported ? null : _reset),
      ]),
    );
  }

  /// Suggestions just above the composer (empty conversation only).
  Widget _chips() => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(S.s4, 0, S.s4, S.s3),
        child: Wrap(alignment: WrapAlignment.start, spacing: S.s2, runSpacing: S.s2, children: [
          for (final s in assistantSuggestions)
            PillChip(label: s.label, lead: Icon(s.icon, size: 14, color: C.t2), onTap: () => _suggest(s)),
        ]),
      );

  Widget _body(AgentCard? card, Conn conn, String host, bool empty, bool working) {
    if (_unsupported) {
      return const _Intro(
        title: 'Needs a newer Loft',
        text: 'The Loft on the laptop doesn\'t have the assistant yet. Update Loft there, then come back.',
      );
    }
    final banners = <Widget>[
      if (!conn.online && conn.loaded && !conn.connecting)
        ChatBanner(icon: LucideIcons.wifiOff, title: '$host is offline', text: 'The assistant runs on the laptop.', action: 'Retry', onAction: () => ref.read(connProvider.notifier).retry().then((_) => _boot()))
      else if (_error != null && !_error!.offline)
        ChatBanner(icon: LucideIcons.triangleAlert, color: C.failed, title: 'Couldn\'t reach the assistant', text: _error!.message, action: 'Retry', onAction: _boot),
    ];
    if (_booting && _id == null && !_log.loaded) return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    if (empty && !_waiting) {
      return Column(children: [
        ...banners.map((b) => Padding(padding: const EdgeInsets.fromLTRB(S.s4, S.s4, S.s4, 0), child: b)),
        const Expanded(
          child: _Intro(
            title: 'What should Loft do?',
            text: 'Start a task, stop or archive agents, find what needs you. Just say it.',
          ),
        ),
      ]);
    }
    final rows = _log.rows();
    final pending = _page?.prompt;
    final open = _log.openTool;
    final asking = card?.col == Col.needs;
    final running = card?.col == Col.running;
    final entries = <Widget>[
      if (asking)
        PickerCard(
          key: ValueKey('picker:${pending?.tool}'),
          prompt: pending,
          state: _picker,
          detail: card!.detail,
          showBody: false,
          busy: answering,
          onAnswer: (s) => answerQuestion(card.id, s),
          onPermission: (n, l) => answerPermission(card.id, pending!, n, l),
          onQuickReply: (t) => _send(t),
          onOther: _other,
        ),
      if (working && !asking) const Align(alignment: Alignment.centerLeft, child: TypingDots()),
      for (final r in rows.reversed)
        switch (r) {
          ToolsRow(:final tools) => _LoftCommands(key: ValueKey(r.key), tools: tools, log: _log, live: running ? open?.tool : null),
          MsgRow(:final item) when item.kind == ChatKind.user => _UserBubble(item, key: ValueKey(item.id)),
          MsgRow(:final item) when item.kind == ChatKind.assistant =>
            SelectionArea(key: ValueKey(item.id), child: Markdown(item.text, style: T.body.copyWith(height: 26 / 16))),
          _ => ChatRowView(log: _log, row: r, pending: pending, asking: asking, running: running, open: open),
        },
      ...banners.reversed,
    ];
    return ListView.separated(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(S.s5, S.s4, S.s5, S.s4),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: S.s4),
      itemBuilder: (_, i) => entries[i],
    );
  }
}

class _Intro extends StatelessWidget {
  final String title, text;
  const _Intro({required this.title, required this.text});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: S.s8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const LoftMark(size: 40),
          const SizedBox(height: S.s4),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontFamily: F.sans, fontSize: 22, fontWeight: FontWeight.w600, color: C.t1)),
          const SizedBox(height: S.s2),
          Text(text, textAlign: TextAlign.center, style: T.secondary.copyWith(fontSize: 14)),
        ]),
      ));
}

/// The user's message: a soft rounded bubble on the right.
class _UserBubble extends StatelessWidget {
  final ChatItem item;
  const _UserBubble(this.item, {super.key});
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .78),
          child: Opacity(
            opacity: item.local ? .6 : 1,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              decoration: BoxDecoration(color: C.selected, borderRadius: BorderRadius.circular(20)),
              child: SelectableText(item.text, style: T.body),
            ),
          ),
        ),
      );
}

/// Tool calls folded into one quiet line: "Ran 2 Loft commands ▸"; tap for the steps.
class _LoftCommands extends StatefulWidget {
  final List<ChatItem> tools;
  final ChatLog log;
  final String? live;
  const _LoftCommands({super.key, required this.tools, required this.log, this.live});
  @override
  State<_LoftCommands> createState() => _LoftCommandsState();
}

class _LoftCommandsState extends State<_LoftCommands> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final n = widget.tools.length;
    final running = widget.live != null && widget.tools.any((t) => t.tool == widget.live);
    final failed = widget.tools.any((t) => widget.log.resultFor(t)?.ok == false);
    final label = running ? 'Running a Loft command…' : 'Ran $n Loft command${n == 1 ? '' : 's'}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        button: true,
        expanded: _open,
        child: InkWell(
          borderRadius: BorderRadius.circular(R.sm),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(failed ? LucideIcons.triangleAlert : LucideIcons.terminal, size: 14, color: failed ? C.failed : C.t3),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(fontFamily: F.sans, fontSize: 14, color: C.t3)),
              const SizedBox(width: 4),
              Icon(_open ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 14, color: C.t3),
            ]),
          ),
        ),
      ),
      if (_open)
        Padding(
          padding: const EdgeInsets.only(top: S.s2),
          child: ToolSteps(tools: widget.tools, resultFor: widget.log.resultFor, live: widget.live),
        ),
    ]);
  }
}

/// Three soft dots while the assistant works.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key});
  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    return Semantics(
      label: 'Loft is working',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(20)),
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 5),
              Opacity(
                opacity: still ? .6 : .3 + .7 * (1 - ((_c.value * 3 - i) % 3 - .5).abs().clamp(0, 1)),
                child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: C.t2, shape: BoxShape.circle)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// A big rounded composer pinned at the bottom: the field grows with the text;
/// mic and send sit inside it. While listening it shows the live words.
class _Composer extends StatelessWidget {
  final VoiceController voice;
  final TextEditingController field;
  final FocusNode focus;
  final String hostName, placeholder;
  final bool laptopReachable;
  final String? chip, banner;
  final VoidCallback? onChipCancel;
  final VoidCallback onSend;
  final Future<void> Function(String) onTranscript;
  const _Composer({
    required this.voice,
    required this.field,
    required this.focus,
    required this.hostName,
    required this.placeholder,
    required this.laptopReachable,
    required this.onSend,
    required this.onTranscript,
    this.chip,
    this.banner,
    this.onChipCancel,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([voice, field]),
        builder: (context, _) {
          final listening = voice.listening, transcribing = voice.phase == VoicePhase.transcribing;
          final hasText = field.text.trim().isNotEmpty;
          final canSend = hasText && !listening && !transcribing;
          final live = voice.live;
          const textStyle = TextStyle(fontFamily: F.sans, fontSize: 16, height: 22 / 16, color: C.t1);
          final String? note = transcribing
              ? (voice.phoneSpeech ? 'Finishing on the phone…' : 'Transcribing on $hostName…')
              : voice.error != null && !listening
                  ? voice.error
                  : listening
                      ? 'Listening ${clock(voice.elapsed)} · tap the mic to stop'
                      : null;
          return Padding(
            padding: const EdgeInsets.fromLTRB(S.s3, 0, S.s3, S.s2),
            child: SafeArea(
              top: false,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final (text, cancel) in [(chip, onChipCancel), (banner, null)])
                  if (text != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(S.s3, 0, S.s3, S.s2),
                      child: Row(children: [
                        Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.caption.copyWith(color: C.needs, fontWeight: FontWeight.w500))),
                        if (cancel != null) InkWell(onTap: cancel, child: const Padding(padding: EdgeInsets.all(4), child: Text('Cancel', style: T.label))),
                      ]),
                    ),
                Container(
                  decoration: BoxDecoration(
                    color: C.raised,
                    border: Border.all(color: listening ? C.t3 : C.borderStrong),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  padding: const EdgeInsets.fromLTRB(S.s4, 6, 6, 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: listening || transcribing
                            ? ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 132),
                                child: SingleChildScrollView(
                                  reverse: true,
                                  child: Text.rich(
                                    TextSpan(children: [
                                      if (hasText) TextSpan(text: '${field.text.trim()} '),
                                      TextSpan(text: live.stable),
                                      if (live.tail.isNotEmpty) TextSpan(text: '${live.stable.isEmpty ? '' : ' '}${live.tail}', style: const TextStyle(color: C.t3)),
                                      if (live.stable.isEmpty && live.tail.isEmpty && !hasText) const TextSpan(text: 'Say it…', style: TextStyle(color: C.t3)),
                                    ]),
                                    style: textStyle,
                                  ),
                                ),
                              )
                            : TextField(
                                controller: field,
                                focusNode: focus,
                                minLines: 1,
                                maxLines: 6,
                                textCapitalization: TextCapitalization.sentences,
                                style: textStyle,
                                decoration: InputDecoration.collapsed(hintText: placeholder, hintStyle: const TextStyle(fontFamily: F.sans, fontSize: 16, color: C.t3)),
                              ),
                      ),
                    ),
                    const SizedBox(width: S.s2),
                    MicButton(voice: voice, size: 40, onDone: onTranscript),
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Send',
                      child: Material(
                        color: canSend ? C.primary : C.selected,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: canSend ? onSend : null,
                          child: SizedBox(width: 40, height: 40, child: Icon(LucideIcons.arrowUp, size: 20, color: canSend ? C.onPrimary : C.t3)),
                        ),
                      ),
                    ),
                  ]),
                ),
                SizedBox(
                  height: 22,
                  child: Center(
                    child: Text(
                      note ?? (laptopReachable ? 'Tap the mic and say it · it sends when you stop' : 'Phone speech · $hostName unreachable'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.caption.copyWith(color: voice.error != null && !listening ? C.failed : C.t3),
                    ),
                  ),
                ),
              ]),
            ),
          );
        },
      );
}
