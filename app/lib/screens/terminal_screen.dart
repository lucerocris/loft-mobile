import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../data/models.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../voice/voice_controller.dart';
import '../widgets/agent_menu.dart';
import '../widgets/common.dart';
import '../widgets/voice_dock.dart';

const loftTerminalTheme = TerminalTheme(
  cursor: C.t1,
  selection: Color(0x4D5B8DFF),
  foreground: C.t1,
  background: C.canvas,
  black: Color(0xFF15171A),
  red: C.failed,
  green: C.personal,
  yellow: C.needs,
  blue: C.work,
  magenta: Color(0xFFC08AF0),
  cyan: Color(0xFF5BC8D6),
  white: C.t2,
  brightBlack: C.t3,
  brightRed: Color(0xFFFF8A7E),
  brightGreen: Color(0xFF6FD99C),
  brightYellow: Color(0xFFF7CB75),
  brightBlue: Color(0xFF86AAFF),
  brightMagenta: Color(0xFFD4AAF7),
  brightCyan: Color(0xFF86DCE6),
  brightWhite: C.t1,
  searchHitBackground: C.needs,
  searchHitBackgroundCurrent: C.failed,
  searchHitForeground: C.onPrimary,
);

/// Figma 7 · Terminal: live `claude attach` over `/ws/term/<id>`. Back only detaches.
class TerminalScreen extends ConsumerStatefulWidget {
  final String id;
  const TerminalScreen({super.key, required this.id});
  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final _term = Terminal(maxLines: 5000);
  final _termCtl = TerminalController();
  final _focus = FocusNode();
  late final VoiceController _voice;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  String _status = 'connecting…';
  bool _attached = false;
  (int, int)? _size;

  @override
  void initState() {
    super.initState();
    _voice = VoiceController(client: () => ref.read(clientProvider), laptopReachable: () => ref.read(connProvider).online);
    _term.onOutput = (data) => _ws?.sink.add(utf8.encode(data));
    _term.onResize = (w, h, pw, ph) {
      _size = (w, h);
      _sendResize();
    };
    _connect();
  }

  void _sendResize() {
    final s = _size;
    if (s == null || _ws == null) return;
    _ws!.sink.add(jsonEncode({'type': 'resize', 'cols': s.$1, 'rows': s.$2}));
  }

  Future<void> _connect() async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    setState(() {
      _status = 'connecting…';
      _attached = false;
    });
    try {
      final ws = await c.terminal(widget.id);
      if (!mounted) {
        ws.sink.close();
        return;
      }
      _ws = ws;
      final decoder = const Utf8Decoder(allowMalformed: true);
      final sink = decoder.startChunkedConversion(_StringSink(_term.write));
      _wsSub = ws.stream.listen((m) {
        if (m is List<int>) {
          sink.add(m);
        } else if (m is String) {
          _term.write(m);
        }
      }, onDone: () => _detached('detached'), onError: (_) => _detached('connection lost'));
      setState(() {
        _status = 'attached · live';
        _attached = true;
      });
      _sendResize();
    } catch (e) {
      _detached('can\'t attach');
    }
  }

  void _detached(String why) {
    _ws = null;
    if (mounted) {
      setState(() {
        _status = why;
        _attached = false;
      });
    }
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _ws?.sink.close(); // detaches only; the agent keeps running
    _voice.dispose();
    _focus.dispose();
    _termCtl.dispose();
    super.dispose();
  }

  void _key(String seq) {
    HapticFeedback.selectionClick();
    _ws?.sink.add(utf8.encode(seq));
  }

  /// Bracketed paste at the agent's prompt; no Enter (that's its own key).
  void _paste(String text) {
    if (text.trim().isEmpty) return;
    _ws?.sink.add(utf8.encode('\x1b[200~${text.trim()}\x1b[201~'));
  }

  @override
  Widget build(BuildContext context) {
    final card = ref.watch(connProvider).snap.byId(widget.id);
    final placeholder = AgentCard(id: widget.id, kind: 'agent', name: 'Agent', work: false, col: Col.running);
    final c = card ?? placeholder;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(children: [
          SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.all(S.s1),
              child: Row(children: [
                IconBtn(LucideIcons.arrowLeft, tooltip: 'Back (detaches)', onTap: () => context.pop()),
                const SizedBox(width: S.s1),
                Expanded(child: AgentTitle(card: c, status: _status)),
                if (c.col == Col.needs) IconBtn(LucideIcons.messageSquare, tooltip: 'Question', onTap: () => context.pushReplacement('/agent/${c.id}')),
                if (card != null) SizedBox(width: 48, height: 48, child: AgentMenuButton(card: card)),
              ]),
            ),
          ),
          const Divider(height: 1, color: C.border),
          Expanded(
            child: Stack(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
                child: TerminalView(
                  _term,
                  controller: _termCtl,
                  focusNode: _focus,
                  theme: loftTerminalTheme,
                  textStyle: const TerminalStyle(fontSize: 12, fontFamily: F.mono, height: 1.3),
                  keyboardType: TextInputType.text,
                  deleteDetection: true,
                  backgroundOpacity: 1,
                ),
              ),
              if (!_attached)
                Positioned.fill(
                  child: Container(
                    color: C.canvas.withValues(alpha: .92),
                    alignment: Alignment.center,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_status == 'connecting…' ? 'Attaching…' : 'Detached ($_status)', style: T.secondary),
                      const SizedBox(height: S.s3),
                      if (_status != 'connecting…') Btn('Reconnect', onTap: _connect, icon: LucideIcons.refreshCw),
                    ]),
                  ),
                ),
              ListenableBuilder(
                listenable: _voice,
                builder: (_, _) => !_voice.busy
                    ? const SizedBox.shrink()
                    : Positioned(
                        left: 12,
                        right: 12,
                        bottom: 8,
                        child: Container(
                          padding: const EdgeInsets.all(S.s3),
                          decoration: BoxDecoration(color: C.raised, border: Border.all(color: C.borderStrong), borderRadius: BorderRadius.circular(R.md)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              const Dot(C.failed),
                              const SizedBox(width: S.s2),
                              Text(_voice.listening ? 'Listening' : 'Transcribing…', style: const TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: C.t1)),
                              const SizedBox(width: S.s2),
                              Text(clock(_voice.elapsed), style: T.mono13),
                              const SizedBox(width: S.s2),
                              Flexible(child: ClipRect(child: LevelBars(_voice.levels.sublist(6)))),
                            ]),
                            if (_voice.text.isNotEmpty) ...[
                              const SizedBox(height: S.s2),
                              Text(_voice.text, style: const TextStyle(fontFamily: F.sans, fontSize: 15, color: C.t1)),
                            ],
                          ]),
                        ),
                      ),
              ),
            ]),
          ),
          Container(
            decoration: const BoxDecoration(color: C.surface, border: Border(top: BorderSide(color: C.border))),
            padding: const EdgeInsets.only(top: 9, bottom: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      _Key(icon: LucideIcons.keyboard, label: 'Keyboard', onTap: () {
                        _focus.requestFocus();
                        SystemChannels.textInput.invokeMethod('TextInput.show');
                      }),
                      _Key(text: 'Esc', label: 'Escape', onTap: () => _key('\x1b')),
                      _Key(text: '^C', label: 'Control C', onTap: () => _key('\x03')),
                      _Key(text: 'Tab', label: 'Tab', onTap: () => _key('\t')),
                      _Key(icon: LucideIcons.cornerDownLeft, label: 'Enter', onTap: () => _key('\r')),
                      _Key(icon: LucideIcons.arrowUp, label: 'Up', onTap: () => _key('\x1b[A')),
                      _Key(icon: LucideIcons.arrowDown, label: 'Down', onTap: () => _key('\x1b[B')),
                      _Key(icon: LucideIcons.arrowLeft, label: 'Left', onTap: () => _key('\x1b[D')),
                      _Key(icon: LucideIcons.arrowRight, label: 'Right', onTap: () => _key('\x1b[C')),
                    ]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: S.s2, right: 12),
                  child: ListenableBuilder(
                    listenable: _voice,
                    builder: (_, _) => MicButton(voice: _voice, size: 48, onDone: (t) async => _paste(t)),
                  ),
                ),
              ]),
              const SizedBox(height: S.s2),
              const Text('Mic pastes what you said at the prompt. Enter sends it.', style: T.caption),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  final IconData? icon;
  final String? text;
  final String label;
  final VoidCallback onTap;
  const _Key({this.icon, this.text, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Semantics(
          button: true,
          label: label,
          child: Material(
            color: C.raised,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sm), side: const BorderSide(color: C.borderStrong)),
            child: InkWell(
              borderRadius: BorderRadius.circular(R.sm),
              onTap: onTap,
              child: SizedBox(
                height: 44,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 44),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: text == null ? 0 : 14),
                    child: Center(
                      widthFactor: 1,
                      child: icon != null ? Icon(icon, size: 18, color: C.t1) : Text(text!, style: const TextStyle(fontFamily: F.mono, fontSize: 13, color: C.t1)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class _StringSink implements Sink<String> {
  final void Function(String) out;
  _StringSink(this.out);
  @override
  void add(String data) => out(data);
  @override
  void close() {}
}
