import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/grouping.dart';
import '../data/models.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

/// A row in a picker sheet: optional lead, title + one line, check when picked.
class OptionRow extends StatelessWidget {
  final Widget? lead;
  final String title;
  final String? subtitle;
  final bool selected, chevron;
  final VoidCallback onTap;
  const OptionRow({super.key, this.lead, required this.title, this.subtitle, this.selected = false, this.chevron = false, required this.onTap});
  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? C.raised : Colors.transparent,
          borderRadius: BorderRadius.circular(R.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(R.md),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  if (lead != null) ...[SizedBox(width: 20, child: Center(child: lead)), const SizedBox(width: 12)],
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(title, style: TextStyle(fontFamily: F.sans, fontSize: 15, fontWeight: FontWeight.w500, color: C.t1)),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[const SizedBox(height: 1), Text(subtitle!, style: T.secondary.copyWith(color: C.t3))],
                    ]),
                  ),
                  if (selected) Icon(LucideIcons.check, size: 20, color: C.t1),
                  if (chevron) Icon(LucideIcons.chevronRight, size: 18, color: C.t3),
                ]),
              ),
            ),
          ),
        ),
      );
}

class SheetTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const SheetTitle(this.title, {super.key, this.subtitle});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontFamily: F.sans, fontSize: 17, fontWeight: FontWeight.w600, color: C.t1)),
          if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.secondary.copyWith(color: C.t3))],
        ]),
      );
}

Future<V?> showPickerSheet<V>(BuildContext context, List<Widget> Function(BuildContext) children) => showModalBottomSheet<V>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .85),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(S.s5, 0, S.s5, S.s4),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children(ctx)),
          ),
        ),
      ),
    );

String _names(Iterable<String> l) {
  final x = l.toList();
  if (x.length <= 3) return x.join(', ');
  return '${x.take(3).join(', ')} +${x.length - 3}';
}

/// Figma Flexible · Mobile B: the Group by sheet. Returns the pick (null = dismissed).
Future<GroupBy?> showGroupBySheet(BuildContext context, Snapshot snap, GroupBy current) {
  final projects = snap.projects ?? const <Project>[];
  String sub(GroupBy g) => switch (g) {
        GroupBy.status => 'Needs you, Working, Todo, Done',
        GroupBy.account => _names(snap.accounts.map((a) => a.label)),
        GroupBy.project => projects.isEmpty ? 'No projects yet' : '${projects.length} ${projects.length == 1 ? 'project' : 'projects'} and Unsorted',
        GroupBy.folder => 'One group per repo or folder',
        GroupBy.none => 'One list, newest first',
      };
  return showPickerSheet<GroupBy>(
    context,
    (ctx) => [
      const SheetTitle('Group by'),
      for (final g in groupChoices(snap))
        OptionRow(
          title: groupByLabel(g),
          subtitle: sub(g),
          selected: g == current,
          onTap: () {
            if (g == GroupBy.project && projects.isEmpty) {
              Navigator.pop(ctx, g);
              context.push('/projects?new=1');
              return;
            }
            Navigator.pop(ctx, g);
          },
        ),
      if (snap.supportsProjects) ...[
        const Padding(padding: EdgeInsets.symmetric(vertical: S.s2), child: Divider(height: 1)),
        OptionRow(
          lead: Icon(LucideIcons.folderKanban, size: 20, color: C.t2),
          title: projects.isEmpty ? 'Create project' : 'Projects',
          subtitle: projects.isEmpty ? 'Group agents by client or product, across accounts' : 'Create, edit, pick accounts and folders',
          chevron: true,
          onTap: () {
            Navigator.pop(ctx);
            context.push(projects.isEmpty ? '/projects?new=1' : '/projects');
          },
        ),
      ],
    ],
  );
}

/// One-line account summary for a project: "Studio, Overflow · Auto".
String projectAccountsLine(Snapshot snap, Project p) {
  final names = p.accounts.isEmpty ? 'Any account' : _names(p.accounts.map(snap.accountLabel));
  if (!snap.multiAccount) return '';
  final d = p.defaultAccount == autoAccount ? 'Auto' : (snap.account(p.defaultAccount)?.label ?? '');
  return d.isEmpty || (p.accounts.length == 1) ? names : '$names · $d';
}

/// Sentinel for "New project…" in the move sheet.
const newProjectPick = '__new';

/// Figma F: Move to project. Returns a project id, [unsortedKey] for "By
/// folder" (clear the manual choice), [newProjectPick], or null (dismissed).
Future<String?> showMoveToProjectSheet(BuildContext context, Snapshot snap, AgentCard card) {
  final current = snap.projectOf(card)?.id;
  return showPickerSheet<String>(
    context,
    (ctx) => [
      SheetTitle('Move to project', subtitle: card.name),
      for (final p in snap.projects ?? const <Project>[])
        OptionRow(
          lead: MarkDot(Mark.square, Color(p.color), size: 12),
          title: p.name,
          subtitle: projectAccountsLine(snap, p),
          selected: p.id == current,
          onTap: () => Navigator.pop(ctx, p.id),
        ),
      OptionRow(
        lead: MarkDot(Mark.hollow, C.t3, size: 12),
        title: 'By folder',
        subtitle: 'No manual choice: follows the folder it works in',
        selected: current == null,
        onTap: () => Navigator.pop(ctx, unsortedKey),
      ),
      const Padding(padding: EdgeInsets.symmetric(vertical: S.s2), child: Divider(height: 1)),
      OptionRow(lead: Icon(LucideIcons.plus, size: 20, color: C.t2), title: 'New project…', onTap: () => Navigator.pop(ctx, newProjectPick)),
    ],
  );
}

/// Move to account (more than two accounts). Returns an account id.
Future<String?> showMoveToAccountSheet(BuildContext context, Snapshot snap, AgentCard card) => showPickerSheet<String>(
      context,
      (ctx) => [
        SheetTitle('Move to account', subtitle: card.name),
        for (final a in snap.accounts)
          OptionRow(
            lead: Dot(Color(a.color)),
            title: a.label,
            subtitle: a.email,
            selected: a.id == card.account,
            onTap: () => Navigator.pop(ctx, a.id),
          ),
      ],
    );
