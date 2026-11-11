/// Snapshot model: mirrors server.py snapshot() (GET /api/state, /api/events).
library;

enum Col { needs, running, todo, done }

Col _col(String? s) => switch (s) {
      'needs' => Col.needs,
      'running' => Col.running,
      'todo' => Col.todo,
      _ => Col.done,
    };

/// Named account/project colors, the same set as desktop Loft (loft/accounts.py COLORS).
const loftPalette = <String, int>{
  'blue': 0xFF5B8DFF,
  'green': 0xFF46C07D,
  'purple': 0xFFA98BFF,
  'cyan': 0xFF3EC1D3,
  'pink': 0xFFF17DB8,
  'orange': 0xFFF2924A,
  'yellow': 0xFFE3CF5B,
  'red': 0xFFF0685A,
};
const _paletteOrder = ['blue', 'green', 'purple', 'cyan', 'pink', 'orange', 'yellow', 'red'];

/// A color from the server: "#RRGGBB", a palette name, or nothing (then by position).
int parseColor(Object? hex, Object? name, int index) {
  for (final v in [hex, name]) {
    if (v is! String || v.isEmpty) continue;
    if (loftPalette.containsKey(v)) return loftPalette[v]!;
    final h = v.replaceFirst('#', '');
    if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(h)) return 0xFF000000 | int.parse(h, radix: 16);
  }
  return loftPalette[_paletteOrder[index % _paletteOrder.length]]!;
}

String _folderName(String cwd) {
  final t = cwd.replaceAll(RegExp(r'/+$'), '');
  if (t.isEmpty || t == '~') return 'home';
  return t.substring(t.lastIndexOf('/') + 1);
}

class AgentCard {
  final String id;
  final String kind; // agent | todo
  final String name;
  /// Account id (from the laptop's account list). null = a login Loft doesn't know.
  final String? account;
  /// Legacy flag from older servers: true for the non-default account.
  final bool work;
  final Col col;
  final String state;
  final String detail;
  final String result;
  final String cwd;
  /// Project id (servers with projects only). null = Unsorted.
  final String? projectId;
  final DateTime? updated;
  final bool live;
  final bool pinned;
  final bool failed;
  /// A queued account switch ("after this turn"), when the server sends one.
  final String? pendingAccount;

  const AgentCard({
    required this.id,
    required this.kind,
    required this.name,
    required this.col,
    this.account,
    this.work = false,
    this.state = '',
    this.detail = '',
    this.result = '',
    this.cwd = '',
    this.projectId,
    this.updated,
    this.live = false,
    this.pinned = false,
    this.failed = false,
    this.pendingAccount,
  });

  bool get isTodo => kind == 'todo';
  bool get isAgent => kind == 'agent';
  bool get noPrompt => detail.isEmpty || detail == '(no prompt yet)';

  /// The folder's last part ("e8-ops-automation"; "home" for ~).
  String get folderName => _folderName(cwd);

  /// The one line under the title in the inbox.
  String get line {
    if (isTodo) return noPrompt ? 'Not started' : detail;
    if (col == Col.done && result.isNotEmpty) return result;
    return detail;
  }

  /// [projects]: the server sends `card.project` as a project id (flex servers).
  /// Older servers send the folder name there, which is ignored.
  factory AgentCard.fromJson(Map<String, dynamic> j, {bool projects = false}) {
    final work = j['work'] == true;
    final p = j['project'];
    return AgentCard(
      id: '${j['id']}',
      kind: '${j['kind'] ?? 'agent'}',
      name: '${j['name'] ?? ''}',
      account: j.containsKey('account') ? (j['account'] == null ? null : '${j['account']}') : (work ? 'work' : 'personal'),
      work: work,
      col: _col(j['col'] as String?),
      state: '${j['state'] ?? ''}',
      detail: '${j['detail'] ?? ''}',
      result: '${j['result'] ?? ''}',
      cwd: '${j['folder'] ?? j['cwd'] ?? ''}',
      projectId: projects && p is String && p.isNotEmpty ? p : null,
      updated: j['updated'] == null ? null : DateTime.tryParse('${j['updated']}'),
      live: j['live'] == true,
      pinned: j['pinned'] == true,
      failed: j['failed'] == true,
      pendingAccount: j['pendingAccount'] is String && (j['pendingAccount'] as String).isNotEmpty ? j['pendingAccount'] as String : null,
    );
  }
}

class UsageWindow {
  final String five, seven;
  const UsageWindow(this.five, this.seven);

  static int? pct(String s) => int.tryParse(s.replaceAll('%', '').trim());
  int? get fivePct => pct(five);
  int? get sevenPct => pct(seven);

  /// The fuller of the two windows, 0..1 (drives the meter bar).
  double get fill {
    final v = [fivePct, sevenPct].whereType<int>();
    return v.isEmpty ? 0 : (v.reduce((a, b) => a > b ? a : b) / 100).clamp(0, 1).toDouble();
  }

  bool get hot => fill >= .85; // "Turns amber at 85%" (Figma Usage meter)

  static const unknown = UsageWindow('—', '—');

  factory UsageWindow.fromJson(Map<String, dynamic>? j) => UsageWindow('${j?['five'] ?? '—'}', '${j?['seven'] ?? '—'}');
}

/// One Claude login on the laptop, as the server lists it.
class Account {
  final String id, label, email;
  final int color;
  final bool isDefault;
  const Account({required this.id, required this.label, required this.color, this.email = '', this.isDefault = false});

  factory Account.fromJson(Map<String, dynamic> j, int i) => Account(
        id: '${j['id']}',
        label: '${j['label'] ?? j['id']}',
        color: parseColor(j['hex'], j['color'], i),
        email: '${j['email'] ?? ''}',
        isDefault: j['default'] == true,
      );
}

/// "auto" as a default account: the allowed account with the lowest 5h usage.
const autoAccount = 'auto';

class Project {
  final String id, name, emoji;
  final int color;
  final String colorName;
  final List<String> accounts; // [] = any account
  final String defaultAccount; // account id, "auto", or "" (Loft's default)
  final List<String> folders;
  final int? count;

  const Project({
    required this.id,
    required this.name,
    required this.color,
    this.colorName = '',
    this.emoji = '',
    this.accounts = const [],
    this.defaultAccount = '',
    this.folders = const [],
    this.count,
  });

  factory Project.fromJson(Map<String, dynamic> j, int i) {
    final c = j['counts'] ?? j['count'];
    return Project(
      id: '${j['id']}',
      name: '${j['name'] ?? j['id']}',
      color: parseColor(j['hex'], j['color'], i),
      colorName: j['color'] is String ? j['color'] as String : '',
      emoji: '${j['emoji'] ?? ''}',
      accounts: [for (final a in (j['accounts'] as List? ?? const [])) '$a'],
      defaultAccount: '${j['defaultAccount'] ?? ''}',
      folders: [for (final f in (j['folders'] as List? ?? const [])) '$f'],
      count: c is int ? c : (c is Map && c['total'] is int ? c['total'] as int : null),
    );
  }

  /// Body for POST/PATCH /api/projects.
  Map<String, dynamic> toJson() => {
        'name': name,
        'color': colorName.isNotEmpty ? colorName : '#${(color & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
        'accounts': accounts,
        'defaultAccount': defaultAccount.isEmpty ? autoAccount : defaultAccount,
        'folders': folders,
      };
}

class Snapshot {
  final List<AgentCard> cards;
  final List<Account> accounts;
  final Map<String, UsageWindow> usage; // by account id
  final String? defaultAccount;
  /// null = the server doesn't know about projects (older Loft): hide project UI.
  final List<Project>? projects;
  /// The server's default grouping ("status", "account", "project", "folder", "none").
  final String? groupBy;
  final List<String> dirs;
  final bool voice;
  /// The JSON this came from (cached for the offline view).
  final Map<String, dynamic> raw;

  const Snapshot({
    this.cards = const [],
    this.accounts = const [],
    this.usage = const {},
    this.defaultAccount,
    this.projects,
    this.groupBy,
    this.dirs = const [],
    this.voice = false,
    this.raw = const {},
  });

  static const empty = Snapshot();

  factory Snapshot.fromJson(Map<String, dynamic> j) {
    final usageJ = (j['usage'] as Map?)?.cast<String, dynamic>() ?? const {};
    final usage = {for (final e in usageJ.entries) e.key: UsageWindow.fromJson((e.value as Map?)?.cast<String, dynamic>())};
    final projJ = j['projects'];
    final hasProjects = projJ is List;
    final cards = [for (final c in (j['cards'] as List? ?? const [])) AgentCard.fromJson((c as Map).cast<String, dynamic>(), projects: hasProjects)];
    var accounts = <Account>[];
    final accJ = j['accounts'];
    if (accJ is List) {
      accounts = [for (final (i, a) in accJ.indexed) Account.fromJson((a as Map).cast<String, dynamic>(), i)];
    } else {
      // Older Loft (one fixed pair): the accounts are the usage keys.
      final ids = usage.keys.isNotEmpty ? usage.keys.toList() : {for (final c in cards) ?c.account}.toList();
      accounts = [
        for (final (i, id) in ids.indexed) Account(id: id, label: id.isEmpty ? id : id[0].toUpperCase() + id.substring(1), color: parseColor(null, null, i)),
      ];
    }
    return Snapshot(
      cards: cards,
      accounts: accounts,
      usage: usage,
      defaultAccount: j['defaultAccount'] is String ? j['defaultAccount'] as String : null,
      projects: hasProjects ? [for (final (i, p) in projJ.indexed) Project.fromJson((p as Map).cast<String, dynamic>(), i)] : null,
      groupBy: j['groupBy'] is String ? j['groupBy'] as String : null,
      dirs: [for (final d in (j['dirs'] as List? ?? const [])) '$d'],
      voice: j['voice'] == true,
      raw: j,
    );
  }

  bool get supportsProjects => projects != null;
  bool get multiAccount => accounts.length > 1;

  AgentCard? byId(String id) {
    for (final c in cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  Account? account(String? id) {
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  Project? project(String? id) {
    if (id == null) return null;
    for (final p in projects ?? const <Project>[]) {
      if (p.id == id) return p;
    }
    return null;
  }

  UsageWindow usageOf(String id) => usage[id] ?? UsageWindow.unknown;

  String accountLabel(String? id) => account(id)?.label ?? 'Other login';

  /// The card's project, if it has one the server still knows.
  Project? projectOf(AgentCard c) => project(c.projectId);

  /// The account a new task goes to: [choice] is an id, "auto" or "" (Loft's default).
  /// Auto = the allowed account with the lowest 5h usage (unknown usage last).
  Account? resolveAccount(String choice, {Project? project}) {
    final allowed = [for (final a in accounts) if (project == null || project.accounts.isEmpty || project.accounts.contains(a.id)) a];
    if (choice == autoAccount) {
      if (allowed.isEmpty) return null;
      int key(Account a) => usageOf(a.id).fivePct ?? 1000;
      return allowed.reduce((a, b) => key(b) < key(a) ? b : a);
    }
    return account(choice) ?? account(defaultAccount) ?? accounts.where((a) => a.isDefault).firstOrNull ?? allowed.firstOrNull ?? accounts.firstOrNull;
  }

  /// Cards in one status section, filtered by account ('' = all), pinned first then newest.
  List<AgentCard> section(Col col, String account) {
    final l = cards.where((c) => c.col == col && (account.isEmpty || c.account == account)).toList();
    l.sort(byPinThenNewest);
    return l;
  }

  Set<String> get needsIds => {for (final c in cards) if (c.col == Col.needs) c.id};
}

int byPinThenNewest(AgentCard a, AgentCard b) {
  if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
  return (b.updated ?? DateTime(0)).compareTo(a.updated ?? DateTime(0));
}

class TimelineEntry {
  final String at, state, detail;
  const TimelineEntry(this.at, this.state, this.detail);
  factory TimelineEntry.fromJson(Map<String, dynamic> j) => TimelineEntry('${j['at'] ?? ''}', '${j['state'] ?? ''}', '${j['detail'] ?? ''}');
}

/// "47m", "3h", "now": the same short age as desktop Loft.
String ago(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final s = (now ?? DateTime.now()).toUtc().difference(t.toUtc()).inSeconds;
  if (s < 60) return 'now';
  if (s >= 86400) return '${s ~/ 86400}d';
  if (s >= 3600) return '${s ~/ 3600}h';
  return '${s ~/ 60}m';
}

/// Splits an agent's question into the explanation and the actual ask
/// (the last sentence, when it ends with "?"), as the Figma "It's asking" screen shows.
({String body, String question}) splitAsk(String detail) {
  final t = detail.trim();
  if (!t.endsWith('?')) return (body: t, question: '');
  final m = RegExp(r'(?:^|[.!?:\n]\s+)([^.!?\n]*\?)$').firstMatch(t);
  if (m == null) return (body: '', question: t);
  final q = m.group(1)!.trim();
  final body = t.substring(0, t.length - q.length).trim();
  return (body: body, question: q);
}

/// Same rule as server.py derive_title(): a short title from the first clause.
String deriveTitle(String prompt) {
  final first0 = prompt.trim().split(RegExp(r'(?<=[.!?\n])\s')).first.trim();
  var first = first0.replaceAll(RegExp(r'[.!?]+$'), '');
  first = first.replaceFirst(RegExp(r'^(please|can you|could you|i want you to|go and)\s+', caseSensitive: false), '');
  final words = first.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '';
  final title = words.take(7).join(' ') + (words.length > 7 ? '…' : '');
  return title[0].toUpperCase() + title.substring(1);
}
