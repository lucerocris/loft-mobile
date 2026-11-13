import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/fs.dart';
import '../data/loft_client.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

/// Loads one folder: (path, show hidden folders).
typedef FsLoader = Future<FsListing> Function(String path, bool hidden);

/// Opens the folder picker over New task. Returns the picked folder as Loft
/// shows it ("~/clients/acme-web"), or null when dismissed.
Future<String?> showFolderPicker(BuildContext context, {required FsLoader load, String start = '~', String host = 'the laptop'}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        // Above the keyboard while filtering.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .92 - MediaQuery.viewInsetsOf(ctx).bottom,
          child: FolderPicker(load: load, start: start, host: host),
        ),
      ),
    );

/// Breadcrumb, up, filter, the folder list with git badges, Recent at home,
/// and "Use this folder". Pops with the picked display path.
class FolderPicker extends StatefulWidget {
  final FsLoader load;
  final String start;
  final String host;
  const FolderPicker({super.key, required this.load, this.start = '~', this.host = 'the laptop'});
  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  final _filter = TextEditingController();
  final _crumbScroll = ScrollController();
  FsListing? _listing;
  bool _loading = true;
  bool _hidden = false;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _filter.addListener(() => setState(() {}));
    _open(widget.start);
  }

  @override
  void dispose() {
    _filter.dispose();
    _crumbScroll.dispose();
    super.dispose();
  }

  Future<void> _open(String path) async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final l = await widget.load(path, _hidden);
      if (!mounted || seq != _seq) return;
      setState(() {
        _listing = l;
        _loading = false;
        _filter.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_crumbScroll.hasClients) _crumbScroll.jumpTo(_crumbScroll.position.maxScrollExtent);
      });
    } on LoftError catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = e.status == 403
            ? 'Loft only opens folders inside your home folder.'
            : e.status == 404 && _listing != null
                ? 'That folder is gone.'
                : e.message;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _toggleHidden() {
    setState(() => _hidden = !_hidden);
    _open(_listing?.path ?? widget.start);
  }

  @override
  Widget build(BuildContext context) {
    final l = _listing;
    final dirs = l?.filtered(_filter.text) ?? const <FsDir>[];
    final showRecent = l != null && l.atHome && l.recent.isNotEmpty && _filter.text.trim().isEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Title row
      Padding(
        padding: const EdgeInsets.fromLTRB(S.s5, 0, S.s2, 0),
        child: Row(children: [
          const Expanded(child: Text('Choose a folder', style: TextStyle(fontFamily: F.sans, fontSize: 17, fontWeight: FontWeight.w600, color: C.t1))),
          IconBtn(_hidden ? LucideIcons.eye : LucideIcons.eyeOff,
              tooltip: _hidden ? 'Hide hidden folders' : 'Show hidden folders', size: 20, color: _hidden ? C.t1 : C.t2, onTap: _toggleHidden),
          IconBtn(LucideIcons.x, tooltip: 'Close', onTap: () => Navigator.pop(context)),
        ]),
      ),
      // Breadcrumb + up
      Padding(
        padding: const EdgeInsets.fromLTRB(S.s3, 0, S.s4, 0),
        child: Row(children: [
          IconBtn(LucideIcons.arrowUp, tooltip: 'Up one folder', size: 20, onTap: l?.parent == null || _loading ? null : () => _open(l!.parent!)),
          const SizedBox(width: S.s1),
          Expanded(
            child: SizedBox(
              height: 40,
              child: ListView(
                controller: _crumbScroll,
                scrollDirection: Axis.horizontal,
                children: [
                  for (final (i, c) in breadcrumbs(l?.display ?? widget.start).indexed) ...[
                    if (i > 0) const Center(child: Padding(padding: EdgeInsets.symmetric(horizontal: 2), child: Icon(LucideIcons.chevronRight, size: 14, color: C.t3))),
                    _Crumb(label: c.label, last: c.path == (l?.display ?? widget.start), onTap: () => _open(c.path)),
                  ],
                ],
              ),
            ),
          ),
        ]),
      ),
      // Filter
      Padding(
        padding: const EdgeInsets.fromLTRB(S.s5, S.s2, S.s5, S.s2),
        child: TextField(
          controller: _filter,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: F.sans, fontSize: 15, color: C.t1),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Filter folders',
            hintStyle: const TextStyle(fontFamily: F.sans, fontSize: 15, color: C.t3),
            prefixIcon: const Icon(LucideIcons.search, size: 18, color: C.t3),
            suffixIcon: _filter.text.isEmpty ? null : IconButton(tooltip: 'Clear filter', icon: const Icon(LucideIcons.x, size: 16, color: C.t3), onPressed: _filter.clear),
            filled: true,
            fillColor: C.raised,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.t2)),
          ),
        ),
      ),
      Expanded(
        child: _error != null
            ? _Message(icon: LucideIcons.folderX, text: _error!, action: l == null ? 'Try again' : 'Back to home', onAction: () => _open(l == null ? widget.start : '~'))
            : _loading && l == null
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : Stack(children: [
                    ListView(padding: const EdgeInsets.fromLTRB(S.s3, 0, S.s3, S.s4), children: [
                      if (showRecent) ...[
                        const _Label('Recent'),
                        for (final r in l.recent) _FolderRow(title: r.name, sub: r.display, icon: LucideIcons.history, git: r.git, web: r.web, onTap: () => _open(r.path)),
                        const _Label('In home'),
                      ],
                      for (final d in dirs) _FolderRow(title: d.name, git: d.git, web: d.web, onTap: () => _open(d.path)),
                      if (l != null && dirs.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(S.s6),
                          child: Text(_filter.text.trim().isEmpty ? 'No folders in here.' : 'No folder matches "${_filter.text.trim()}".',
                              textAlign: TextAlign.center, style: T.secondary),
                        ),
                      if (l != null && l.truncated)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(12, S.s3, 12, 0),
                          child: Text('Long folder: only the first ones are listed. Open a subfolder or type the path.', style: T.caption),
                        ),
                    ]),
                    if (_loading) const Positioned(left: 0, right: 0, top: 0, child: LinearProgressIndicator(minHeight: 2, backgroundColor: Colors.transparent)),
                  ]),
      ),
      // Use this folder
      Container(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.border))),
        padding: EdgeInsets.fromLTRB(S.s5, S.s3, S.s5, S.s3 + (MediaQuery.viewInsetsOf(context).bottom > 0 ? 0 : MediaQuery.viewPaddingOf(context).bottom)),
        child: Row(children: [
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('On ${widget.host}', style: T.caption),
              const SizedBox(height: 2),
              Text(l?.display ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: F.mono, fontSize: 13, color: C.t1)),
            ]),
          ),
          const SizedBox(width: S.s3),
          Btn('Use this folder', kind: BtnKind.primary, onTap: l == null || _loading ? null : () => Navigator.pop(context, l.display)),
        ]),
      ),
    ]);
  }
}

class _Crumb extends StatelessWidget {
  final String label;
  final bool last;
  final VoidCallback onTap;
  const _Crumb({required this.label, required this.last, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(R.sm),
        onTap: last ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Center(
            widthFactor: 1,
            child: Text(label,
                style: TextStyle(fontFamily: F.mono, fontSize: 13, fontWeight: last ? FontWeight.w500 : FontWeight.w400, color: last ? C.t1 : C.t2)),
          ),
        ),
      );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(12, S.s3, 12, S.s1), child: Text(text, style: T.label));
}

class _FolderRow extends StatelessWidget {
  final String title;
  final String? sub;
  final IconData icon;
  final bool git, web;
  final VoidCallback onTap;
  const _FolderRow({required this.title, this.sub, this.icon = LucideIcons.folder, this.git = false, this.web = false, required this.onTap});
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: [title, if (git) 'git repository', if (web) 'web project'].join(', '),
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(R.md),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Icon(icon, size: 18, color: C.t3),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.rowTitle),
                    if (sub != null) Text(sub!, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono12),
                  ]),
                ),
                if (git) const _Badge('git', LucideIcons.gitBranch),
                if (web) const _Badge('web', LucideIcons.globe),
                const SizedBox(width: S.s1),
                const Icon(LucideIcons.chevronRight, size: 18, color: C.t3),
              ]),
            ),
          ),
        ),
      );
}

class _Badge extends StatelessWidget {
  final String label;
  final IconData icon;
  const _Badge(this.label, this.icon);
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(border: Border.all(color: C.borderStrong), borderRadius: BorderRadius.circular(R.sm)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: C.t2),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontFamily: F.mono, fontSize: 11, color: C.t2)),
        ]),
      );
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onAction;
  const _Message({required this.icon, required this.text, required this.action, required this.onAction});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(S.s6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 28, color: C.t3),
            const SizedBox(height: S.s3),
            Text(text, textAlign: TextAlign.center, style: T.secondary),
            const SizedBox(height: S.s4),
            Btn(action, onTap: onAction, height: 44),
          ]),
        ),
      );
}
