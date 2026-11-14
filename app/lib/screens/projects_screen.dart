import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/grouping.dart';
import '../data/loft_client.dart';
import '../data/models.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'group_sheet.dart';

/// Figma Flexible · Mobile G: the project list. [startNew] opens the editor
/// for a new project straight away; [assignCard] moves that card into it.
class ProjectsScreen extends ConsumerStatefulWidget {
  final bool startNew;
  final String? assignCard;
  const ProjectsScreen({super.key, this.startNew = false, this.assignCard});
  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.startNew) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(connProvider).snap.supportsProjects) showProjectEditor(context, ref, null, assignCard: widget.assignCard);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(connProvider).snap;
    final projects = snap.projects ?? const <Project>[];
    final active = snap.cards.where((c) => c.col != Col.done).toList();
    final unsorted = active.where((c) => snap.projectOf(c) == null).length;
    String meta(Project p) {
      final n = active.where((c) => snap.projectOf(c)?.id == p.id).length;
      return [
        projectAccountsLine(snap, p),
        if (p.folders.isNotEmpty) '${p.folders.length} ${p.folders.length == 1 ? 'folder' : 'folders'}',
        '$n ${n == 1 ? 'agent' : 'agents'}',
      ].where((x) => x.isNotEmpty).join(' · ');
    }

    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.all(S.s1),
              child: Row(children: [
                IconBtn(LucideIcons.arrowLeft, tooltip: 'Back', onTap: () => context.pop()),
                const SizedBox(width: S.s1),
                Text('Projects', style: TextStyle(fontFamily: F.sans, fontSize: 18, fontWeight: FontWeight.w600, color: C.t1)),
              ]),
            ),
          ),
          Expanded(
            child: !snap.supportsProjects
                ? Padding(
                    padding: EdgeInsets.all(S.s6),
                    child: Text('Loft on the laptop doesn\'t know about projects yet. Update it, then projects show up here.', style: T.secondary),
                  )
                : ListView(padding: const EdgeInsets.fromLTRB(S.s4, S.s2, S.s4, S.s4), children: [
                    Text('An agent joins a project when it works inside one of the project\'s folders. Move one by hand from its ⋮ menu.', style: T.secondary),
                    const SizedBox(height: S.s3),
                    if (projects.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(S.s5),
                        decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.lg)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('No projects yet', style: T.rowTitle),
                          SizedBox(height: 4),
                          Text('Make one per client or product. A project can use one account or several.', style: T.secondary),
                        ]),
                      )
                    else
                      Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.lg)),
                        child: Column(children: [
                          for (final (i, p) in projects.indexed) ...[
                            if (i > 0) const Divider(height: 1, indent: 48),
                            InkWell(
                              onTap: () => showProjectEditor(context, ref, p),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(minHeight: 64),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(S.s4, S.s2, S.s3, S.s2),
                                  child: Row(children: [
                                    MarkDot(Mark.square, Color(p.color), size: 12),
                                    const SizedBox(width: S.s4),
                                    Expanded(
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(p.name, style: T.rowTitle),
                                        Text(meta(p), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.secondary.copyWith(color: C.t3)),
                                      ]),
                                    ),
                                    Icon(LucideIcons.chevronRight, size: 18, color: C.t3),
                                  ]),
                                ),
                              ),
                            ),
                          ],
                        ]),
                      ),
                    if (unsorted > 0) ...[
                      const SizedBox(height: S.s3),
                      Row(children: [
                        const SizedBox(width: S.s1),
                        MarkDot(Mark.hollow, C.t3),
                        const SizedBox(width: S.s2),
                        Text('Unsorted: $unsorted ${unsorted == 1 ? 'agent' : 'agents'} outside every project folder', style: T.secondary.copyWith(color: C.t3)),
                      ]),
                    ],
                  ]),
          ),
          if (snap.supportsProjects)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, S.s2, 20, S.s2),
              child: SizedBox(width: double.infinity, child: Btn('New project', kind: BtnKind.primary, icon: LucideIcons.plus, onTap: () => showProjectEditor(context, ref, null))),
            ),
        ]),
      ),
    );
  }
}

/// Figma H: the project editor sheet (create when [project] is null).
Future<void> showProjectEditor(BuildContext context, WidgetRef ref, Project? project, {String? assignCard}) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _Editor(project: project, assignCard: assignCard),
    );

class _Editor extends ConsumerStatefulWidget {
  final Project? project;
  final String? assignCard;
  const _Editor({this.project, this.assignCard});
  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  late final _name = TextEditingController(text: widget.project?.name ?? '');
  late String _color;
  late List<String> _accounts = [...?widget.project?.accounts];
  late String _default = widget.project?.defaultAccount ?? autoAccount;
  late final List<String> _folders = [...?widget.project?.folders];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.project;
    if (p != null && p.colorName.isNotEmpty && loftPalette.containsKey(p.colorName)) {
      _color = p.colorName;
    } else if (p != null) {
      _color = loftPalette.entries.where((e) => e.value == p.color).firstOrNull?.key ?? 'blue';
    } else {
      final used = {for (final x in ref.read(connProvider).snap.projects ?? const <Project>[]) x.color};
      _color = loftPalette.entries.where((e) => !used.contains(e.value)).firstOrNull?.key ?? 'blue';
    }
    if (_default.isEmpty) _default = autoAccount;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _addFolder(Snapshot snap) async {
    final choices = [for (final d in snap.dirs) if (!_folders.contains(d)) d];
    final picked = await showPickerSheet<String>(
      context,
      (ctx) => [
        const SheetTitle('Add folder', subtitle: 'Agents working inside it join this project'),
        for (final d in choices)
          OptionRow(lead: Icon(LucideIcons.folder, size: 18, color: C.t3), title: d, onTap: () => Navigator.pop(ctx, d)),
        OptionRow(lead: Icon(LucideIcons.pencil, size: 18, color: C.t3), title: 'Type a path…', onTap: () => Navigator.pop(ctx, '')),
      ],
    );
    if (picked == null || !mounted) return;
    var d = picked;
    if (d.isEmpty) {
      final ctl = TextEditingController(text: '~/');
      final v = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Project folder'),
          content: TextField(controller: ctl, autofocus: true, autocorrect: false, style: TextStyle(fontFamily: F.mono, fontSize: 15, color: C.t1), onSubmitted: (s) => Navigator.pop(ctx, s)),
          actions: [
            Btn('Cancel', onTap: () => Navigator.pop(ctx), kind: BtnKind.quiet, height: 44),
            Btn('Add', onTap: () => Navigator.pop(ctx, ctl.text), kind: BtnKind.primary, height: 44),
          ],
        ),
      );
      d = v?.trim().replaceAll(RegExp(r'/+$'), '') ?? '';
    }
    if (d.isEmpty || _folders.contains(d)) return;
    setState(() => _folders.add(d));
  }

  Future<void> _save(Snapshot snap) async {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Give the project a name.');
    final client = ref.read(clientProvider);
    if (client == null) return;
    // The default must be one of the picked accounts (or Auto).
    var dflt = _default;
    if (dflt != autoAccount && _accounts.isNotEmpty && !_accounts.contains(dflt)) dflt = autoAccount;
    final p = Project(id: widget.project?.id ?? '', name: name, color: loftPalette[_color]!, colorName: _color, accounts: _accounts, defaultAccount: dflt, folders: _folders);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.project == null) {
        final made = await client.createProject(p);
        if (widget.assignCard != null && made.id.isNotEmpty) await client.setCardProject(widget.assignCard!, made.id);
      } else {
        await client.updateProject(widget.project!.id, p.toJson());
      }
      await ref.read(connProvider.notifier).retry(); // show it now, not on the next event
      if (mounted) Navigator.pop(context);
    } on LoftError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final p = widget.project!;
    final ok = await confirmDanger(context,
        title: 'Delete "${p.name}"?', body: 'Its agents stay as they are and show under Unsorted. Nothing on the laptop is deleted.', action: 'Delete');
    if (!ok || !mounted) return;
    try {
      await ref.read(clientProvider)!.deleteProject(p.id);
      await ref.read(connProvider.notifier).retry();
      if (mounted) Navigator.pop(context);
    } on LoftError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(connProvider).snap;
    final allowed = _accounts.isEmpty ? snap.accounts : snap.accounts.where((a) => _accounts.contains(a.id)).toList();
    Widget label(String t) => Padding(padding: const EdgeInsets.only(bottom: S.s2, top: S.s4), child: Text(t, style: T.label));
    Widget caption(String t) => Padding(padding: const EdgeInsets.only(top: S.s2), child: Text(t, style: T.caption));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .9),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(S.s5, 0, S.s5, S.s4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Text(widget.project == null ? 'New project' : 'Edit project', style: TextStyle(fontFamily: F.sans, fontSize: 17, fontWeight: FontWeight.w600, color: C.t1)),
              label('Name'),
              TextField(
                controller: _name,
                autofocus: widget.project == null,
                textCapitalization: TextCapitalization.sentences,
                style: T.body,
                decoration: InputDecoration(
                  hintText: 'Client or product name',
                  hintStyle: T.body.copyWith(color: C.t3),
                  filled: true,
                  fillColor: C.raised,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: BorderSide(color: C.borderStrong)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: BorderSide(color: C.t2)),
                ),
              ),
              label('Color'),
              Wrap(spacing: S.s1, runSpacing: S.s1, children: [
                for (final e in loftPalette.entries)
                  Semantics(
                    button: true,
                    selected: e.key == _color,
                    label: e.key,
                    child: InkResponse(
                      onTap: () => setState(() => _color = e.key),
                      radius: 22,
                      child: Container(
                        width: 40,
                        height: 40,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: e.key == _color ? C.t1 : Colors.transparent, width: 2)),
                        child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: Color(e.value))),
                      ),
                    ),
                  ),
              ]),
              if (snap.multiAccount) ...[
                label('Accounts'),
                Wrap(spacing: S.s2, runSpacing: S.s2, children: [
                  for (final a in snap.accounts)
                    FilterChip(
                      selected: _accounts.contains(a.id),
                      showCheckmark: true,
                      checkmarkColor: C.t1,
                      avatar: _accounts.contains(a.id) ? null : Dot(Color(a.color)),
                      label: Text(a.label, style: T.button),
                      backgroundColor: C.raised,
                      selectedColor: C.selected,
                      side: BorderSide(color: _accounts.contains(a.id) ? C.t2 : C.border),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md)),
                      onSelected: (on) => setState(() {
                        _accounts = on ? [..._accounts, a.id] : (_accounts..remove(a.id));
                        _accounts = [for (final x in snap.accounts) if (_accounts.contains(x.id)) x.id];
                      }),
                    ),
                ]),
                caption('None picked = any account.'),
                label('New tasks use'),
                Wrap(spacing: S.s2, runSpacing: S.s2, children: [
                  ChoiceChip(
                    selected: _default == autoAccount,
                    showCheckmark: false,
                    avatar: Icon(LucideIcons.gauge, size: 16, color: _default == autoAccount ? C.t1 : C.t3),
                    label: Text('Auto', style: T.button),
                    backgroundColor: C.raised,
                    selectedColor: C.selected,
                    side: BorderSide(color: _default == autoAccount ? C.t2 : C.border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md)),
                    onSelected: (_) => setState(() => _default = autoAccount),
                  ),
                  for (final a in allowed)
                    ChoiceChip(
                      selected: _default == a.id,
                      showCheckmark: false,
                      avatar: Dot(Color(a.color)),
                      label: Text(a.label, style: T.button),
                      backgroundColor: C.raised,
                      selectedColor: C.selected,
                      side: BorderSide(color: _default == a.id ? C.t2 : C.border),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md)),
                      onSelected: (_) => setState(() => _default = a.id),
                    ),
                ]),
                caption('Auto: the ${_accounts.isEmpty ? '' : 'picked '}account with the most 5h left.'),
              ],
              label('Folders'),
              Container(
                decoration: BoxDecoration(color: C.raised, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.md)),
                child: Column(children: [
                  for (final f in _folders)
                    SizedBox(
                      height: 48,
                      child: Row(children: [
                        const SizedBox(width: 14),
                        Icon(LucideIcons.folder, size: 16, color: C.t3),
                        const SizedBox(width: 10),
                        Expanded(child: Text(f, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: F.mono, fontSize: 13, color: C.t1))),
                        IconBtn(LucideIcons.x, tooltip: 'Remove $f', size: 18, color: C.t3, onTap: () => setState(() => _folders.remove(f))),
                      ]),
                    ),
                  InkWell(
                    onTap: () => _addFolder(snap),
                    child: SizedBox(
                      height: 48,
                      child: Row(children: [
                        SizedBox(width: 14),
                        Icon(LucideIcons.plus, size: 16, color: C.t2),
                        SizedBox(width: 10),
                        Text('Add folder', style: TextStyle(fontFamily: F.sans, fontSize: 14, fontWeight: FontWeight.w500, color: C.t2)),
                      ]),
                    ),
                  ),
                ]),
              ),
              if (_error != null) ...[const SizedBox(height: S.s3), Text(_error!, style: TextStyle(fontFamily: F.sans, fontSize: 13, color: C.failed))],
              const SizedBox(height: S.s5),
              Row(children: [
                if (widget.project != null) ...[Expanded(child: Btn('Delete', onTap: _busy ? null : _delete)), const SizedBox(width: S.s3)],
                Expanded(child: Btn(widget.project == null ? 'Create project' : 'Save', kind: BtnKind.primary, busy: _busy, onTap: () => _save(snap))),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
