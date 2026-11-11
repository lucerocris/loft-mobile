/// Snapshot model: mirrors server.py snapshot() (GET /api/state, /api/events).
library;

enum Col { needs, running, todo, done }

Col _col(String? s) => switch (s) {
      'needs' => Col.needs,
      'running' => Col.running,
      'todo' => Col.todo,
      _ => Col.done,
    };

class AgentCard {
  final String id;
  final String kind; // agent | todo
  final String name;
  final bool work;
  final Col col;
  final String state;
  final String detail;
  final String result;
  final String cwd;
  final String project;
  final DateTime? updated;
  final bool live;
  final bool pinned;
  final bool failed;

  const AgentCard({
    required this.id,
    required this.kind,
    required this.name,
    required this.work,
    required this.col,
    this.state = '',
    this.detail = '',
    this.result = '',
    this.cwd = '',
    this.project = '',
    this.updated,
    this.live = false,
    this.pinned = false,
    this.failed = false,
  });

  bool get isTodo => kind == 'todo';
  bool get isAgent => kind == 'agent';
  bool get noPrompt => detail.isEmpty || detail == '(no prompt yet)';
  String get account => work ? 'work' : 'personal';
  String get accountLabel => work ? 'Work' : 'Personal';
  String get projectLabel => project == '~' ? 'home' : project;

  /// The one line under the title in the inbox.
  String get line {
    if (isTodo) return noPrompt ? 'Not started' : detail;
    if (col == Col.done && result.isNotEmpty) return result;
    return detail;
  }

  factory AgentCard.fromJson(Map<String, dynamic> j) => AgentCard(
        id: '${j['id']}',
        kind: '${j['kind'] ?? 'agent'}',
        name: '${j['name'] ?? ''}',
        work: j['work'] == true,
        col: _col(j['col'] as String?),
        state: '${j['state'] ?? ''}',
        detail: '${j['detail'] ?? ''}',
        result: '${j['result'] ?? ''}',
        cwd: '${j['cwd'] ?? ''}',
        project: '${j['project'] ?? ''}',
        updated: j['updated'] == null ? null : DateTime.tryParse('${j['updated']}'),
        live: j['live'] == true,
        pinned: j['pinned'] == true,
        failed: j['failed'] == true,
      );
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

  factory UsageWindow.fromJson(Map<String, dynamic>? j) => UsageWindow('${j?['five'] ?? '—'}', '${j?['seven'] ?? '—'}');
}

class Snapshot {
  final List<AgentCard> cards;
  final UsageWindow work, personal;
  final List<String> dirs;
  final bool voice;

  const Snapshot({this.cards = const [], this.work = const UsageWindow('—', '—'), this.personal = const UsageWindow('—', '—'), this.dirs = const [], this.voice = false});

  static const empty = Snapshot();

  factory Snapshot.fromJson(Map<String, dynamic> j) {
    final usage = (j['usage'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Snapshot(
      cards: [for (final c in (j['cards'] as List? ?? const [])) AgentCard.fromJson((c as Map).cast<String, dynamic>())],
      work: UsageWindow.fromJson((usage['work'] as Map?)?.cast<String, dynamic>()),
      personal: UsageWindow.fromJson((usage['personal'] as Map?)?.cast<String, dynamic>()),
      dirs: [for (final d in (j['dirs'] as List? ?? const [])) '$d'],
      voice: j['voice'] == true,
    );
  }

  AgentCard? byId(String id) {
    for (final c in cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Cards in one inbox section, filtered by account ('' = all), pinned first then newest.
  List<AgentCard> section(Col col, String account) {
    final l = cards.where((c) => c.col == col && (account.isEmpty || c.account == account)).toList();
    l.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return (b.updated ?? DateTime(0)).compareTo(a.updated ?? DateTime(0));
    });
    return l;
  }

  Set<String> get needsIds => {for (final c in cards) if (c.col == Col.needs) c.id};
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
