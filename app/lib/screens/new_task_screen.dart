import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/grouping.dart';
import '../data/loft_client.dart';
import '../data/models.dart';
import '../data/outbox.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../voice/voice_controller.dart';
import '../widgets/common.dart';
import '../widgets/voice_dock.dart';

/// Figma 5 · New task and 6 · New task · Listening. Text first: opens with the
/// keyboard up; long-pressing the inbox's "New task" button starts listening instead.
/// With [todoId] it edits and starts an existing Todo instead.
class NewTaskScreen extends ConsumerStatefulWidget {
  final bool listen;
  final String? todoId;
  const NewTaskScreen({super.key, this.listen = false, this.todoId});
  @override
  ConsumerState<NewTaskScreen> createState() => _NewTaskScreenState();
}

class _NewTaskScreenState extends ConsumerState<NewTaskScreen> {
  final _prompt = TextEditingController();
  final _focus = FocusNode();
  late final VoiceController _voice;
  String _account = ''; // account id, "auto", or "" (not picked yet)
  String? _project; // project id, null = none
  String? _dir;
  bool _busy = false;
  String? _error;
  final _extraDirs = <String>[];

  AgentCard? get _todo => widget.todoId == null ? null : ref.read(connProvider).snap.byId(widget.todoId!);

  @override
  void initState() {
    super.initState();
    _voice = VoiceController(client: () => ref.read(clientProvider), laptopReachable: () => ref.read(connProvider).online);
    _prompt.addListener(() => setState(() {}));
    final t = _todo;
    if (t != null) {
      _account = t.account ?? '';
      _dir = t.cwd;
      if (!t.noPrompt) _prompt.text = t.detail;
    } else {
      SharedPreferences.getInstance().then((p) {
        if (!mounted) return;
        final snap = ref.read(connProvider).snap;
        final proj = snap.project(p.getString('loft.newProject'));
        setState(() {
          _project = proj?.id;
          final saved = p.getString(proj == null ? 'loft.newAcct' : 'loft.newAcct.${proj.id}') ?? '';
          final choices = accountChoices(snap, proj);
          _account = saved == autoAccount || choices.any((a) => a.id == saved) ? saved : initialAccountChoice(snap, proj);
          _dir = p.getString('loft.dir.${proj?.id ?? _account}') ?? proj?.folders.firstOrNull;
        });
      });
    }
    if (widget.listen) WidgetsBinding.instance.addPostFrameCallback((_) => _voice.start());
  }

  @override
  void dispose() {
    _voice.dispose();
    _prompt.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<String> _dirs(Snapshot snap) {
    // A project's own folders when it has some (Other… adds more), else the recent ones.
    final proj = snap.project(_project);
    final l = <String>[...(proj?.folders.isNotEmpty ?? false) ? proj!.folders : snap.dirs.take(4)];
    for (final d in [..._extraDirs, ?_dir]) {
      if (!l.contains(d)) l.insert(0, d);
    }
    return l.take(6).toList();
  }

  String? _defaultDir(Snapshot snap) => _dir ?? snap.project(_project)?.folders.firstOrNull ?? snap.dirs.firstOrNull;

  /// The account the task goes to, as sent: "" lets the server pick.
  String _accountFor(Snapshot snap) {
    final proj = snap.project(_project);
    final choices = accountChoices(snap, proj);
    if (_account == autoAccount) return snap.supportsProjects ? autoAccount : (snap.resolveAccount(autoAccount, project: proj)?.id ?? '');
    if (choices.any((a) => a.id == _account)) return _account;
    return initialAccountChoice(snap, proj);
  }

  Future<void> _setAccount(String a) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_project == null ? 'loft.newAcct' : 'loft.newAcct.$_project', a);
    setState(() {
      _account = a;
      if (_project == null) _dir = p.getString('loft.dir.$a') ?? _dir;
    });
  }

  Future<void> _setProject(Snapshot snap, String? id) async {
    final p = await SharedPreferences.getInstance();
    if (id == null) {
      await p.remove('loft.newProject');
    } else {
      await p.setString('loft.newProject', id);
    }
    final proj = snap.project(id);
    setState(() {
      _project = id;
      final saved = p.getString(id == null ? 'loft.newAcct' : 'loft.newAcct.$id') ?? '';
      _account = saved == autoAccount || accountChoices(snap, proj).any((a) => a.id == saved) ? saved : initialAccountChoice(snap, proj);
      _dir = proj?.folders.firstOrNull ?? p.getString('loft.dir.${id ?? _account}');
    });
  }

  Future<void> _other() async {
    final ctl = TextEditingController(text: '~/');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Project folder'),
        content: TextField(controller: ctl, autofocus: true, autocorrect: false, style: const TextStyle(fontFamily: F.mono, fontSize: 15, color: C.t1), onSubmitted: (s) => Navigator.pop(ctx, s)),
        actions: [
          Btn('Cancel', onTap: () => Navigator.pop(ctx), kind: BtnKind.quiet, height: 44),
          Btn('Use it', onTap: () => Navigator.pop(ctx, ctl.text), kind: BtnKind.primary, height: 44),
        ],
      ),
    );
    final d = v?.trim().replaceAll(RegExp(r'/+$'), '');
    if (d == null || d.isEmpty) return;
    setState(() {
      _extraDirs.add(d);
      _dir = d;
    });
  }

  Future<void> _submit(bool start) async {
    if (_voice.busy) await _voice.stop();
    final snap = ref.read(connProvider).snap;
    final prompt = _prompt.text.trim();
    final cwd = _defaultDir(snap) ?? '';
    final account = _accountFor(snap);
    final project = snap.supportsProjects ? _project : null;
    if (prompt.isEmpty) return setState(() => _error = start ? 'Say or write what it should do.' : 'Write something to save.');
    if (cwd.isEmpty) return setState(() => _error = 'Pick the project folder it works in.');
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = ref.read(clientProvider)!;
    final todo = _todo;
    try {
      if (!ref.read(connProvider).online && todo == null) {
        await ref.read(connProvider.notifier).enqueue(OutboxItem('create', {'prompt': prompt, 'account': account, 'cwd': cwd, 'start': start, 'project': ?project}));
        if (mounted) {
          toast(context, 'Waiting to ${start ? 'start' : 'save'}: the laptop is offline');
          context.pop();
        }
        return;
      }
      final String msg;
      if (todo != null) {
        msg = start ? await client.act(todo.id, 'start', {'prompt': prompt}) : await client.act(todo.id, 'prompt', {'prompt': prompt});
      } else {
        msg = await client.create(prompt: prompt, account: account, cwd: cwd, start: start, project: project);
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('loft.dir.${project ?? account}', cwd);
      if (!mounted) return;
      toast(context, msg);
      context.pop();
    } on LoftError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Figma Flexible · Mobile E: Project first, then the project's accounts (with
  /// Auto), each only when it applies.
  List<Widget> _pickers(Snapshot snap) {
    final projects = snap.projects ?? const <Project>[];
    final proj = snap.project(_project);
    final choices = accountChoices(snap, proj);
    final showAuto = snap.supportsProjects && choices.length > 1;
    final auto = snap.resolveAccount(autoAccount, project: proj);
    final picked = _account.isEmpty ? initialAccountChoice(snap, proj) : _account;
    Widget label(String t) => Padding(padding: const EdgeInsets.only(bottom: S.s2), child: Text(t, style: T.label));
    return [
      if (projects.isNotEmpty) ...[
        label('Project'),
        Wrap(spacing: S.s2, runSpacing: S.s2, children: [
          for (final p in projects)
            _Chip(label: p.name, selected: p.id == _project, lead: MarkDot(Mark.square, Color(p.color)), onTap: _busy ? null : () => _setProject(snap, p.id)),
          _Chip(label: 'None', selected: _project == null, onTap: _busy ? null : () => _setProject(snap, null)),
        ]),
        const SizedBox(height: S.s5),
      ],
      if (choices.length > 1) ...[
        label('Account'),
        Wrap(spacing: S.s2, runSpacing: S.s2, children: [
          if (showAuto)
            _Chip(label: 'Auto', sub: auto?.label, icon: LucideIcons.gauge, selected: picked == autoAccount, onTap: _busy ? null : () => _setAccount(autoAccount)),
          for (final a in choices) _Chip(label: a.label, selected: picked == a.id, lead: Dot(Color(a.color)), onTap: _busy ? null : () => _setAccount(a.id)),
        ]),
        if (showAuto && picked == autoAccount && auto != null)
          Padding(
            padding: const EdgeInsets.only(top: S.s2),
            child: Text(
                'Auto uses the account with the most 5h left (${auto.label}${snap.usageOf(auto.id).fivePct == null ? '' : ', ${100 - snap.usageOf(auto.id).fivePct!}%'}).',
                style: T.caption),
          ),
        const SizedBox(height: S.s5),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connProvider);
    final snap = conn.snap;
    final todo = _todo;
    final dir = _defaultDir(snap);
    final host = ref.watch(pairingProvider)?.name ?? 'fedora';

    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _voice,
          builder: (context, _) {
            final listening = _voice.listening, transcribing = _voice.phase == VoicePhase.transcribing;
            final title = deriveTitle(_prompt.text);
            return Column(children: [
              SizedBox(
                height: 64,
                child: Padding(
                  padding: const EdgeInsets.all(S.s1),
                  child: Row(children: [
                    IconBtn(LucideIcons.x, tooltip: 'Close', onTap: () => context.pop()),
                    const SizedBox(width: S.s1),
                    Expanded(child: Text(todo == null ? 'New task' : todo.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.screenTitle.copyWith(fontSize: 18))),
                  ]),
                ),
              ),
              Expanded(
                child: ListView(padding: const EdgeInsets.fromLTRB(20, S.s2, 20, S.s4), children: [
                  if (todo == null) ..._pickers(snap),
                  if (todo != null) ...[
                    Row(children: [
                      if (snap.account(todo.account) != null) ...[Dot(Color(snap.account(todo.account)!.color)), const SizedBox(width: S.s2)],
                      Text(['Todo', if (snap.multiAccount) snap.accountLabel(todo.account), ?snap.projectOf(todo)?.name].join(' · '), style: T.label),
                    ]),
                    const SizedBox(height: S.s6),
                  ],
                  const Text('Folder', style: T.label),
                  const SizedBox(height: S.s2),
                  Wrap(spacing: S.s2, runSpacing: S.s2, children: [
                    for (final d in (todo == null ? _dirs(snap) : [todo.cwd]))
                      _Chip(label: d, mono: true, selected: d == dir, icon: LucideIcons.folder, onTap: todo == null ? () => setState(() => _dir = d) : null),
                    if (todo == null) _Chip(label: 'Other…', onTap: _other),
                  ]),
                  const SizedBox(height: S.s6),
                  Container(
                    constraints: const BoxConstraints(minHeight: 220),
                    padding: const EdgeInsets.all(S.s4),
                    decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.lg)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                        height: 24,
                        child: listening
                            ? Row(children: [
                                const Dot(C.failed),
                                const SizedBox(width: S.s2),
                                const Text('Listening', style: TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: C.t1)),
                                const SizedBox(width: S.s2),
                                Text(clock(_voice.elapsed), style: T.mono13),
                                const SizedBox(width: S.s2),
                                Flexible(child: ClipRect(child: LevelBars(_voice.levels))),
                              ])
                            : Align(
                                alignment: Alignment.centerLeft,
                                child: Text(transcribing ? 'Transcribing on $host…' : 'What should it do?',
                                    style: const TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: C.t3)),
                              ),
                      ),
                      const SizedBox(height: S.s3),
                      if (listening || transcribing)
                        Text.rich(
                          TextSpan(children: [
                            if (_prompt.text.trim().isNotEmpty) TextSpan(text: '${_prompt.text.trim()} '),
                            TextSpan(text: _voice.live.stable),
                            if (_voice.live.tail.isNotEmpty) TextSpan(text: '${_voice.live.stable.isEmpty ? '' : ' '}${_voice.live.tail}', style: const TextStyle(color: C.t3)),
                          ]),
                          style: _promptStyle,
                        )
                      else
                        TextField(
                          controller: _prompt,
                          focusNode: _focus,
                          autofocus: !widget.listen && widget.todoId == null,
                          minLines: 3,
                          maxLines: null,
                          textCapitalization: TextCapitalization.sentences,
                          style: _promptStyle,
                          decoration: const InputDecoration.collapsed(hintText: 'Type it, or tap the mic and say it.', hintStyle: TextStyle(fontFamily: F.sans, fontSize: 20, color: C.t3)),
                        ),
                      if (title.isNotEmpty && !listening && todo == null) ...[
                        const SizedBox(height: S.s3),
                        Row(children: [
                          const Text('Title', style: TextStyle(fontFamily: F.sans, fontSize: 12, fontWeight: FontWeight.w500, color: C.t3)),
                          const SizedBox(width: S.s2),
                          Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t2))),
                        ]),
                      ],
                    ]),
                  ),
                  if (_error != null || _voice.error != null) ...[
                    const SizedBox(height: S.s3),
                    Text(_error ?? _voice.error!, style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.failed)),
                  ],
                  const SizedBox(height: S.s6),
                  Center(
                    child: MicButton(
                      voice: _voice,
                      size: 96,
                      onDone: (t) async => deliverTranscript(context, _prompt, t, go: () => _submit(true), goLabel: 'Starting'),
                    ),
                  ),
                  const SizedBox(height: S.s3),
                  Center(
                    child: _voice.phoneSpeech || !conn.online
                        ? Text('Phone speech · $host unreachable, check names', style: T.caption.copyWith(color: C.needs, fontSize: 13))
                        : Text(
                            listening ? 'Tap to stop · end with "start it" to start now' : (_prompt.text.isEmpty ? 'Tap to talk · end with "start it" to start' : 'Tap to talk more · end with "start it" to start'),
                            textAlign: TextAlign.center,
                            style: T.caption.copyWith(fontSize: 13)),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, S.s2, 20, S.s2),
                child: Row(children: [
                  Expanded(child: Btn(todo == null ? 'Save to Todo' : 'Save prompt', onTap: _busy || listening || _prompt.text.trim().isEmpty ? null : () => _submit(false))),
                  const SizedBox(width: S.s3),
                  Expanded(child: Btn('Start', kind: BtnKind.primary, busy: _busy, onTap: listening || _prompt.text.trim().isEmpty ? null : () => _submit(true))),
                ]),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

const _promptStyle = TextStyle(fontFamily: F.sans, fontSize: 20, height: 28 / 20, color: C.t1);

class _Chip extends StatelessWidget {
  final String label;
  final String? sub;
  final bool selected, mono;
  final IconData? icon;
  final Widget? lead;
  final VoidCallback? onTap;
  const _Chip({required this.label, this.selected = false, this.mono = false, this.icon, this.lead, this.sub, this.onTap});
  @override
  Widget build(BuildContext context) => Material(
        color: selected ? C.selected : C.raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md), side: BorderSide(color: selected ? C.t2 : C.border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(R.md),
          onTap: onTap,
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.s3),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 16, color: selected ? C.t1 : C.t3), const SizedBox(width: S.s2)],
                if (lead != null) ...[lead!, const SizedBox(width: S.s2)],
                Text(label,
                    style: TextStyle(
                        fontFamily: mono ? F.mono : F.sans, fontSize: mono ? 13 : 14, fontWeight: selected ? FontWeight.w500 : FontWeight.w400, color: selected ? C.t1 : C.t2)),
                if (sub != null) ...[const SizedBox(width: S.s2), Text(sub!, style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3))],
              ]),
            ),
          ),
        ),
      );
}
