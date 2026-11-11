/// How the inbox is organized: group by status, account, project, folder or
/// nothing, plus the filter chips for the active dimension (docs/flex-contract.md
/// in cagents). Pure logic, no widgets.
library;

import 'models.dart';

enum GroupBy { status, account, project, folder, none }

GroupBy? parseGroupBy(String? s) => GroupBy.values.where((g) => g.name == s).firstOrNull;

/// The groupings that make sense for this laptop: Account only with more than
/// one account, Project only when the server knows about projects.
List<GroupBy> groupChoices(Snapshot s) => [
      GroupBy.status,
      if (s.multiAccount) GroupBy.account,
      if (s.supportsProjects) GroupBy.project,
      GroupBy.folder,
      GroupBy.none,
    ];

/// The phone's choice, else the server's default, else Status; anything that
/// doesn't apply here (Project on an older server) falls back to Status.
GroupBy effectiveGroupBy(String? phonePref, Snapshot s) {
  final want = parseGroupBy(phonePref) ?? parseGroupBy(s.groupBy) ?? GroupBy.status;
  return groupChoices(s).contains(want) ? want : GroupBy.status;
}

String groupByLabel(GroupBy g) => switch (g) {
      GroupBy.status => 'Status',
      GroupBy.account => 'Account',
      GroupBy.project => 'Project',
      GroupBy.folder => 'Folder',
      GroupBy.none => 'None',
    };

/// How a group or filter value is marked: account = dot, project = square,
/// Unsorted / unknown = hollow.
enum Mark { none, dot, square, hollow }

/// Key of the Unsorted project group and filter.
const unsortedKey = '__unsorted';
const doneKey = '__done';

class Group {
  final String key, label;
  final int? color;
  final Mark mark;
  final List<AgentCard> cards;
  final bool alert; // "Needs you"
  final List<String> accounts; // project groups: the project's accounts (header dots)
  const Group(this.key, this.label, this.cards, {this.color, this.mark = Mark.none, this.alert = false, this.accounts = const []});

  bool get isDone => key == doneKey;
  int get needs => cards.where((c) => c.col == Col.needs).length;
}

enum FilterDim { none, account, project, folder }

/// Which values the filter chips show: the grouping's own dimension; with
/// Status or None it is the account (only when there is more than one).
FilterDim filterDim(GroupBy g, Snapshot s) => switch (g) {
      GroupBy.project => FilterDim.project,
      GroupBy.folder => FilterDim.folder,
      _ => s.multiAccount ? FilterDim.account : FilterDim.none,
    };

class FilterOption {
  final String key, label;
  final int? color;
  final Mark mark;
  final int count;
  const FilterOption(this.key, this.label, this.count, {this.color, this.mark = Mark.none});
}

String projectKey(Snapshot s, AgentCard c) => s.projectOf(c)?.id ?? unsortedKey;
String accountKey(AgentCard c) => c.account ?? '';

bool matchesFilter(Snapshot s, AgentCard c, FilterDim d, String key) {
  if (key.isEmpty) return true;
  return switch (d) {
    FilterDim.none => true,
    FilterDim.account => accountKey(c) == key,
    FilterDim.project => projectKey(s, c) == key,
    FilterDim.folder => c.cwd == key,
  };
}

/// Filter chips: All, then each value with its count of cards that aren't done.
List<FilterOption> filterOptions(Snapshot s, FilterDim d) {
  if (d == FilterDim.none) return const [];
  final active = s.cards.where((c) => c.col != Col.done).toList();
  int n(String k) => active.where((c) => matchesFilter(s, c, d, k)).length;
  final out = <FilterOption>[FilterOption('', 'All', active.length)];
  switch (d) {
    case FilterDim.account:
      for (final a in s.accounts) {
        out.add(FilterOption(a.id, a.label, n(a.id), color: a.color, mark: Mark.dot));
      }
    case FilterDim.project:
      for (final p in s.projects ?? const <Project>[]) {
        out.add(FilterOption(p.id, p.name, n(p.id), color: p.color, mark: Mark.square));
      }
      final u = n(unsortedKey);
      if (u > 0) out.add(FilterOption(unsortedKey, 'Unsorted', u, mark: Mark.hollow));
    case FilterDim.folder:
      for (final f in _foldersByActivity(active)) {
        out.add(FilterOption(f, _short(f), n(f)));
      }
    case FilterDim.none:
      break;
  }
  return out;
}

String _short(String cwd) {
  final t = cwd.replaceAll(RegExp(r'/+$'), '');
  if (t.isEmpty || t == '~') return 'home';
  return t.substring(t.lastIndexOf('/') + 1);
}

List<String> _foldersByActivity(List<AgentCard> cards) {
  final latest = <String, DateTime>{};
  for (final c in cards) {
    final t = c.updated ?? DateTime(0);
    if (!latest.containsKey(c.cwd) || latest[c.cwd]!.isBefore(t)) latest[c.cwd] = t;
  }
  return latest.keys.toList()..sort((a, b) => latest[b]!.compareTo(latest[a]!));
}

/// Needs you, then working, then todo, then done; pinned first, then newest.
int byStatus(AgentCard a, AgentCard b) {
  if (a.col != b.col) return a.col.index.compareTo(b.col.index);
  return byPinThenNewest(a, b);
}

/// The inbox's sections. Every grouping ends with one Done group (collapsed in
/// the UI). Empty groups are left out, except Done.
List<Group> buildGroups(Snapshot s, GroupBy g, {String filter = ''}) {
  final dim = filterDim(g, s);
  final shown = s.cards.where((c) => matchesFilter(s, c, dim, filter)).toList();
  final active = shown.where((c) => c.col != Col.done).toList()..sort(byStatus);
  final done = shown.where((c) => c.col == Col.done).toList()..sort(byPinThenNewest);
  final out = <Group>[];
  void addGroup(Group grp) {
    if (grp.cards.isNotEmpty) out.add(grp);
  }

  switch (g) {
    case GroupBy.status:
      List<AgentCard> of(Col col) => active.where((c) => c.col == col).toList()..sort(byPinThenNewest);
      addGroup(Group('needs', 'Needs you', of(Col.needs), alert: true));
      addGroup(Group('running', 'Working', of(Col.running)));
      addGroup(Group('todo', 'Todo', of(Col.todo)));
    case GroupBy.account:
      for (final a in s.accounts) {
        addGroup(Group(a.id, a.label, active.where((c) => c.account == a.id).toList(), color: a.color, mark: Mark.dot));
      }
      final known = {for (final a in s.accounts) a.id};
      addGroup(Group('', 'Other login', active.where((c) => !known.contains(c.account)).toList(), mark: Mark.hollow));
    case GroupBy.project:
      for (final p in s.projects ?? const <Project>[]) {
        addGroup(Group(p.id, p.name, active.where((c) => s.projectOf(c)?.id == p.id).toList(),
            color: p.color, mark: Mark.square, accounts: p.accounts.isEmpty ? [for (final a in s.accounts) a.id] : p.accounts));
      }
      addGroup(Group(unsortedKey, 'Unsorted', active.where((c) => s.projectOf(c) == null).toList(), mark: Mark.hollow));
    case GroupBy.folder:
      for (final f in _foldersByActivity(active)) {
        addGroup(Group(f, _short(f), active.where((c) => c.cwd == f).toList()));
      }
    case GroupBy.none:
      addGroup(Group('__all', '', active));
  }
  out.add(Group(doneKey, 'Done', done));
  return out;
}

/// Accounts a new task can use for [project] (all of them when it allows any).
List<Account> accountChoices(Snapshot s, Project? project) =>
    [for (final a in s.accounts) if (project == null || project.accounts.isEmpty || project.accounts.contains(a.id)) a];

/// The account choice a new task starts with: the project's default ("auto"
/// or an id), else Loft's default account.
String initialAccountChoice(Snapshot s, Project? project) {
  final choices = accountChoices(s, project);
  final d = project?.defaultAccount ?? '';
  if (d == autoAccount && choices.length > 1) return autoAccount;
  if (choices.any((a) => a.id == d)) return d;
  final dflt = s.defaultAccount ?? s.accounts.where((a) => a.isDefault).firstOrNull?.id;
  if (choices.any((a) => a.id == dflt)) return dflt!;
  return choices.firstOrNull?.id ?? '';
}
