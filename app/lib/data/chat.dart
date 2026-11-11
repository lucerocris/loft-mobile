/// The chat view of a session: GET `/api/cards/<id>/messages` (Loft's
/// loft/transcript.py) and POST `/api/cards/<id>/answer` (loft/prompts.py).
library;

enum ChatKind { user, assistant, tool, result, question, note, unknown }

ChatKind _kind(Object? s) => switch (s) {
      'user' => ChatKind.user,
      'assistant' => ChatKind.assistant,
      'tool' => ChatKind.tool,
      'result' => ChatKind.result,
      'question' => ChatKind.question,
      'note' => ChatKind.note,
      _ => ChatKind.unknown,
    };

class ChatOption {
  final String label, description;
  const ChatOption(this.label, [this.description = '']);
  factory ChatOption.fromJson(Map j) => ChatOption('${j['label'] ?? ''}', '${j['description'] ?? ''}');
}

class ChatQuestion {
  final String question, header;
  final bool multi;
  final List<ChatOption> options;
  const ChatQuestion({required this.question, this.header = '', this.multi = false, this.options = const []});
  factory ChatQuestion.fromJson(Map j) => ChatQuestion(
        question: '${j['question'] ?? ''}',
        header: '${j['header'] ?? ''}',
        multi: j['multi'] == true,
        options: [for (final o in (j['options'] as List? ?? const [])) if (o is Map) ChatOption.fromJson(o)],
      );
}

class ChatItem {
  final String id;
  final ChatKind kind;
  final DateTime? at;
  final String text; // user, assistant, note; a result's full text
  final int images;
  // tool / question
  final String tool; // tool_use id
  final String name, title, detail, plan;
  // result
  final String forTool;
  final bool ok;
  final String preview;
  final int lines;
  final bool cut;
  final int? add, del;
  final List<ChatQuestion> questions;
  /// Sent from this phone, not in the transcript yet.
  final bool local;

  const ChatItem({
    required this.id,
    required this.kind,
    this.at,
    this.text = '',
    this.images = 0,
    this.tool = '',
    this.name = '',
    this.title = '',
    this.detail = '',
    this.plan = '',
    this.forTool = '',
    this.ok = true,
    this.preview = '',
    this.lines = 0,
    this.cut = false,
    this.add,
    this.del,
    this.questions = const [],
    this.local = false,
  });

  factory ChatItem.fromJson(Map<String, dynamic> j) {
    final diff = j['diff'] is Map ? j['diff'] as Map : null;
    return ChatItem(
      id: '${j['id'] ?? ''}',
      kind: _kind(j['kind']),
      at: j['at'] is String ? DateTime.tryParse(j['at'] as String) : null,
      text: '${j['text'] ?? ''}',
      images: j['images'] is int ? j['images'] as int : 0,
      tool: '${j['tool'] ?? ''}',
      name: '${j['name'] ?? ''}',
      title: '${j['title'] ?? ''}',
      detail: '${j['detail'] ?? ''}',
      plan: '${j['plan'] ?? ''}',
      forTool: '${j['for'] ?? ''}',
      ok: j['ok'] != false,
      preview: '${j['preview'] ?? ''}',
      lines: j['lines'] is int ? j['lines'] as int : 0,
      cut: j['cut'] == true,
      add: diff?['add'] is int ? diff!['add'] as int : null,
      del: diff?['del'] is int ? diff!['del'] as int : null,
      questions: [for (final q in (j['questions'] as List? ?? const [])) if (q is Map) ChatQuestion.fromJson(q)],
    );
  }
}

enum PromptKind { question, permission }

/// What the agent waits on: an AskUserQuestion, or a permission / plan approval.
class PendingPrompt {
  final PromptKind kind;
  final String tool;
  final List<ChatQuestion> questions;
  final String title, action;
  final List<(int, String)> options; // permission: (number, label)
  const PendingPrompt({required this.kind, required this.tool, this.questions = const [], this.title = '', this.action = '', this.options = const []});

  static PendingPrompt? fromJson(Object? o) {
    if (o is! Map) return null;
    final kind = o['kind'] == 'question' ? PromptKind.question : (o['kind'] == 'permission' ? PromptKind.permission : null);
    if (kind == null || o['tool'] is! String) return null;
    return PendingPrompt(
      kind: kind,
      tool: o['tool'] as String,
      questions: [for (final q in (o['questions'] as List? ?? const [])) if (q is Map) ChatQuestion.fromJson(q)],
      title: '${o['title'] ?? ''}',
      action: '${o['action'] ?? ''}',
      options: [
        for (final x in (o['options'] as List? ?? const []))
          if (x is Map && x['n'] is int) (x['n'] as int, '${x['label'] ?? ''}')
      ],
    );
  }

  /// A plan approval rather than a tool permission.
  bool get isPlan => action == 'approve plan' || title.toLowerCase().contains('plan');
}

class ChatPage {
  final List<ChatItem> items;
  final int cursor, start;
  final bool more, gap, reset, working;
  final String? session;
  final String state, detail;
  final bool needs;
  final String pendingText;
  final PendingPrompt? prompt;

  const ChatPage({
    this.items = const [],
    this.cursor = 0,
    this.start = 0,
    this.more = false,
    this.gap = false,
    this.reset = false,
    this.working = false,
    this.session,
    this.state = '',
    this.detail = '',
    this.needs = false,
    this.pendingText = '',
    this.prompt,
  });

  factory ChatPage.fromJson(Map<String, dynamic> j) {
    final p = j['pending'] is Map ? j['pending'] as Map : null;
    PendingPrompt? prompt = PendingPrompt.fromJson(p?['prompt']);
    // A server between the chat and picker releases sends only the question.
    if (prompt == null && p?['question'] is Map) {
      final q = p!['question'] as Map;
      prompt = PendingPrompt.fromJson({'kind': 'question', 'tool': q['tool'], 'questions': q['questions']});
    }
    int n(Object? v) => v is int ? v : (v is String ? int.tryParse(v) ?? 0 : 0);
    return ChatPage(
      items: [for (final i in (j['items'] as List? ?? const [])) if (i is Map) ChatItem.fromJson(i.cast<String, dynamic>())],
      cursor: n(j['cursor']),
      start: n(j['start']),
      more: j['more'] == true,
      gap: j['gap'] == true,
      reset: j['reset'] == true,
      working: j['working'] == true,
      session: j['session'] as String?,
      state: '${j['state'] ?? ''}',
      detail: '${j['detail'] ?? ''}',
      needs: p != null,
      pendingText: '${p?['text'] ?? ''}',
      prompt: prompt,
    );
  }
}

/// One row of the chat list.
sealed class ChatRow {
  String get key;
}

class MsgRow extends ChatRow {
  final ChatItem item;
  MsgRow(this.item);
  @override
  String get key => item.id;
}

/// Consecutive tool calls, shown as one block of compact rows.
class ToolsRow extends ChatRow {
  final List<ChatItem> tools;
  ToolsRow(this.tools);
  @override
  String get key => 'tools:${tools.first.id}';
}

/// The chat so far, merged from pages (first page, older pages, new items).
class ChatLog {
  final List<ChatItem> items = []; // everything but results
  final Map<String, ChatItem> results = {}; // by tool_use id
  String? session;
  int cursor = 0, start = 0;
  bool more = false, loaded = false;

  void apply(ChatPage p, {bool older = false}) {
    final first = !loaded || p.reset || (!older && session != null && p.session != session);
    if (first) {
      final locals = items.where((i) => i.local).toList();
      items
        ..clear()
        ..addAll(locals);
      results.clear();
    }
    session = p.session;
    final known = {for (final i in items) i.id};
    final fresh = <ChatItem>[];
    for (final it in p.items) {
      if (it.kind == ChatKind.result) {
        results[it.forTool] = it;
      } else if (!known.contains(it.id) && it.kind != ChatKind.unknown) {
        fresh.add(it);
      }
    }
    if (older) {
      items.insertAll(items.indexWhere((i) => !i.local).clamp(0, items.length), fresh);
      start = p.start;
      more = p.more;
      return;
    }
    for (final f in fresh.where((f) => f.kind == ChatKind.user)) {
      final i = items.indexWhere((x) => x.local && x.text.trim() == f.text.trim());
      if (i >= 0) items.removeAt(i);
    }
    final locals = items.where((i) => i.local).toList();
    items
      ..removeWhere((i) => i.local)
      ..addAll(fresh)
      ..addAll(locals);
    cursor = p.cursor;
    if (first) {
      start = p.start;
      more = p.more;
    }
    loaded = true;
  }

  void addLocal(String text) => items.add(ChatItem(id: 'local-${DateTime.now().microsecondsSinceEpoch}', kind: ChatKind.user, text: text, local: true, at: DateTime.now()));

  ChatItem? resultFor(ChatItem tool) => results[tool.tool];

  /// The tool call still waiting for its result (the live one), if the last thing is a tool.
  ChatItem? get openTool {
    for (final i in items.reversed) {
      if (i.local) continue;
      if (i.kind == ChatKind.tool) return results.containsKey(i.tool) ? null : i;
      return null;
    }
    return null;
  }

  List<ChatRow> rows() {
    final out = <ChatRow>[];
    for (final it in items) {
      final plain = it.kind == ChatKind.tool && it.plan.isEmpty;
      if (plain && out.isNotEmpty && out.last is ToolsRow) {
        (out.last as ToolsRow).tools.add(it);
      } else if (plain) {
        out.add(ToolsRow([it]));
      } else {
        out.add(MsgRow(it));
      }
    }
    return out;
  }
}

/// The phone's picks for a [PendingPrompt] question, step by step.
class PickerState {
  final PendingPrompt prompt;
  int step = 0;
  final Map<int, int> single = {};
  final Map<int, Set<int>> multi = {};
  final Map<int, String> other = {};
  PickerState(this.prompt);

  List<ChatQuestion> get qs => prompt.questions;
  ChatQuestion get current => qs[step];
  bool get isLast => step >= qs.length - 1;
  bool get many => qs.length > 1;

  bool answered(int i) {
    final q = qs[i];
    if ((other[i] ?? '').trim().isNotEmpty) return true;
    return q.multi ? (multi[i]?.isNotEmpty ?? false) : single.containsKey(i);
  }

  bool get complete => [for (var i = 0; i < qs.length; i++) answered(i)].every((x) => x);

  void pick(int option) {
    if (current.multi) {
      final s = multi.putIfAbsent(step, () => <int>{});
      if (!s.remove(option)) s.add(option);
    } else {
      single[step] = option;
      other.remove(step);
    }
  }

  void setOther(int i, String text) {
    final t = text.trim();
    if (t.isEmpty) {
      other.remove(i);
    } else {
      other[i] = t;
      if (!qs[i].multi) single.remove(i);
    }
  }

  /// The POST body's "answers".
  List<Map<String, dynamic>> answers() => [
        for (var i = 0; i < qs.length; i++)
          if (qs[i].multi)
            {'choices': (multi[i] ?? <int>{}).toList()..sort(), if ((other[i] ?? '').isNotEmpty) 'other': other[i]}
          else if ((other[i] ?? '').isNotEmpty)
            {'other': other[i]}
          else
            {'choice': single[i]}
      ];

  /// What the answer says, for the Undo toast ("Thin · Cheese, Basil").
  String summary() => [
        for (var i = 0; i < qs.length; i++)
          [
            if (qs[i].multi) ...[for (final o in (multi[i]?.toList() ?? <int>[])..sort()) qs[i].options[o].label] else if (single[i] != null) qs[i].options[single[i]!].label,
            if ((other[i] ?? '').isNotEmpty) other[i]!,
          ].join(', ')
      ].join(' · ');
}

// ------------------------------------------------------------------ markdown
sealed class MdBlock {}

class MdPara extends MdBlock {
  final String text;
  MdPara(this.text);
}

class MdHeading extends MdBlock {
  final int level;
  final String text;
  MdHeading(this.level, this.text);
}

class MdCode extends MdBlock {
  final String lang, code;
  MdCode(this.lang, this.code);
}

class MdList extends MdBlock {
  final bool ordered;
  final int start;
  final List<String> items;
  MdList(this.ordered, this.items, [this.start = 1]);
}

class MdQuote extends MdBlock {
  final String text;
  MdQuote(this.text);
}

class MdRule extends MdBlock {}

final _fence = RegExp(r'^\s*(```|~~~)\s*([\w+#.-]*)\s*$');
final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _bullet = RegExp(r'^\s*[-*+]\s+(.*)$');
final _ordered = RegExp(r'^\s*(\d+)[.)]\s+(.*)$');
final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');

/// A small Markdown reader: paragraphs, headings, fenced code, lists, quotes,
/// rules. Tables come back as code blocks (they need the fixed width).
List<MdBlock> parseMarkdown(String src) {
  final lines = src.replaceAll('\r\n', '\n').split('\n');
  final out = <MdBlock>[];
  final para = <String>[];
  void flush() {
    if (para.isNotEmpty) out.add(MdPara(para.join('\n').trim()));
    para.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final l = lines[i];
    final f = _fence.firstMatch(l);
    if (f != null) {
      flush();
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith(f.group(1)!)) {
        code.add(lines[i]);
        i++;
      }
      out.add(MdCode(f.group(2) ?? '', code.join('\n')));
      i++;
      continue;
    }
    if (l.trim().isEmpty) {
      flush();
      i++;
      continue;
    }
    if (l.trimLeft().startsWith('|')) {
      flush();
      final t = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
        t.add(lines[i].trim());
        i++;
      }
      out.add(MdCode('table', t.join('\n')));
      continue;
    }
    final h = _heading.firstMatch(l);
    if (h != null) {
      flush();
      out.add(MdHeading(h.group(1)!.length, h.group(2)!.trim()));
      i++;
      continue;
    }
    if (_rule.hasMatch(l)) {
      flush();
      out.add(MdRule());
      i++;
      continue;
    }
    if (_bullet.hasMatch(l) || _ordered.hasMatch(l)) {
      flush();
      final ordered = !_bullet.hasMatch(l);
      final start = ordered ? int.tryParse(_ordered.firstMatch(l)!.group(1)!) ?? 1 : 1;
      final items = <String>[];
      while (i < lines.length) {
        final m = ordered ? _ordered.firstMatch(lines[i]) : _bullet.firstMatch(lines[i]);
        if (m != null) {
          items.add(m.group(ordered ? 2 : 1)!.trim());
        } else if (lines[i].trim().isNotEmpty && lines[i].startsWith(RegExp(r'\s{2,}')) && items.isNotEmpty) {
          items[items.length - 1] = '${items.last}\n${lines[i].trim()}'; // continued or nested line
        } else {
          break;
        }
        i++;
      }
      out.add(MdList(ordered, items, start));
      continue;
    }
    if (l.trimLeft().startsWith('>')) {
      flush();
      final q = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
        q.add(lines[i].trimLeft().substring(1).trimLeft());
        i++;
      }
      out.add(MdQuote(q.join('\n')));
      continue;
    }
    para.add(l);
    i++;
  }
  flush();
  return out;
}

enum MdStyle { plain, code, bold, italic, link }

class MdSpan {
  final String text;
  final MdStyle style;
  const MdSpan(this.text, [this.style = MdStyle.plain]);
  @override
  String toString() => '${style.name}:$text';
}

final _inline = RegExp(r'`([^`\n]+)`|\*\*([^*\n]+)\*\*|__([^_\n]+)__|(?<![\w*])\*([^*\n]+)\*(?!\w)|\[([^\]\n]+)\]\(([^)\s]+)\)');

/// Inline Markdown: `code`, **bold**, *italic*, [links](url) (shown as their text).
List<MdSpan> parseInline(String s) {
  final out = <MdSpan>[];
  var last = 0;
  for (final m in _inline.allMatches(s)) {
    if (m.start > last) out.add(MdSpan(s.substring(last, m.start)));
    if (m.group(1) != null) {
      out.add(MdSpan(m.group(1)!, MdStyle.code));
    } else if (m.group(2) != null || m.group(3) != null) {
      out.add(MdSpan(m.group(2) ?? m.group(3)!, MdStyle.bold));
    } else if (m.group(4) != null) {
      out.add(MdSpan(m.group(4)!, MdStyle.italic));
    } else {
      out.add(MdSpan(m.group(5)!, MdStyle.link));
    }
    last = m.end;
  }
  if (last < s.length) out.add(MdSpan(s.substring(last)));
  return out;
}
