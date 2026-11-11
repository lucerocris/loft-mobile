import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/chat.dart';
import '../data/models.dart';
import '../theme/tokens.dart';
import 'common.dart';

// Figma "Chat view · Mobile" frames 1–15.

const _codeColor = Color(0xFFD7D9DD);

TextSpan inlineSpan(String text, TextStyle base) {
  final mono = base.copyWith(fontFamily: F.mono, fontSize: (base.fontSize ?? 16) - 2, color: _codeColor, backgroundColor: C.raised);
  return TextSpan(style: base, children: [
    for (final s in parseInline(text))
      switch (s.style) {
        MdStyle.code => TextSpan(text: s.text, style: mono),
        MdStyle.bold => TextSpan(text: s.text, style: const TextStyle(fontWeight: FontWeight.w600)),
        MdStyle.italic => TextSpan(text: s.text, style: const TextStyle(fontStyle: FontStyle.italic)),
        MdStyle.link => TextSpan(text: s.text, style: const TextStyle(decoration: TextDecoration.underline, decorationColor: C.t3)),
        MdStyle.plain => TextSpan(text: s.text),
      }
  ]);
}

/// Assistant prose: readable type, code blocks that scroll sideways.
class Markdown extends StatelessWidget {
  final String text;
  final TextStyle style;
  const Markdown(this.text, {super.key, this.style = T.body});

  @override
  Widget build(BuildContext context) {
    final blocks = parseMarkdown(text);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, b) in blocks.indexed) ...[
        if (i > 0) SizedBox(height: b is MdHeading ? S.s4 : S.s3),
        _block(b),
      ],
    ]);
  }

  Widget _block(MdBlock b) => switch (b) {
        MdPara(:final text) => Text.rich(inlineSpan(text, style)),
        MdHeading(:final level, :final text) =>
          Text.rich(inlineSpan(text, style.copyWith(fontSize: level <= 1 ? 19 : (level == 2 ? 17 : 16), height: 24 / 17, fontWeight: FontWeight.w600))),
        MdCode(:final lang, :final code) => CodeBlock(code: code, lang: lang),
        MdList(:final ordered, :final items, :final start) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, it) in items.indexed)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: ordered ? 24 : 16, child: Text(ordered ? '${start + i}.' : '•', style: style.copyWith(color: C.t3))),
                  Expanded(child: Text.rich(inlineSpan(it, style))),
                ]),
              ),
          ]),
        MdQuote(:final text) => Container(
            padding: const EdgeInsets.only(left: S.s3),
            decoration: const BoxDecoration(border: Border(left: BorderSide(color: C.borderStrong, width: 2))),
            child: Text.rich(inlineSpan(text, style.copyWith(color: C.t2))),
          ),
        MdRule() => const Divider(color: C.border, height: 1),
      };
}

class CodeBlock extends StatelessWidget {
  final String code, lang;
  const CodeBlock({super.key, required this.code, this.lang = ''});
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 2, 0),
            child: Row(children: [
              Expanded(child: Text(lang == 'table' ? '' : lang, style: const TextStyle(fontFamily: F.mono, fontSize: 11, color: C.t3))),
              IconButton(
                tooltip: 'Copy',
                visualDensity: VisualDensity.compact,
                icon: const Icon(LucideIcons.copy, size: 15, color: C.t3),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  toast(context, 'Copied');
                },
              ),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(code, style: const TextStyle(fontFamily: F.mono, fontSize: 13, height: 20 / 13, color: C.t1)),
          ),
        ]),
      );
}

class UserBubble extends StatelessWidget {
  final ChatItem item;
  const UserBubble(this.item, {super.key});
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .82),
          child: Opacity(
            opacity: item.local ? .6 : 1,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              decoration: BoxDecoration(
                color: C.raised,
                border: Border.all(color: C.borderStrong),
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(R.lg), topRight: Radius.circular(R.lg), bottomLeft: Radius.circular(R.lg), bottomRight: Radius.circular(4)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                if (item.text.isNotEmpty) SelectableText(item.text, style: T.body),
                if (item.images > 0)
                  Padding(
                    padding: EdgeInsets.only(top: item.text.isEmpty ? 0 : 6),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(LucideIcons.image, size: 14, color: C.t3),
                      const SizedBox(width: 6),
                      Text(item.images == 1 ? '1 image' : '${item.images} images', style: T.caption),
                    ]),
                  ),
                if (item.local) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Sending…', style: T.caption)),
              ]),
            ),
          ),
        ),
      );
}

class NoteRow extends StatelessWidget {
  final String text;
  const NoteRow(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Row(children: [
        const Expanded(child: Divider(color: C.border, height: 1)),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text(text, style: T.caption, textAlign: TextAlign.center)),
        const Expanded(child: Divider(color: C.border, height: 1)),
      ]);
}

IconData toolIcon(String name) {
  final n = name.toLowerCase();
  if (n == 'bash') return LucideIcons.terminal;
  if (n == 'read') return LucideIcons.fileText;
  if (n == 'edit' || n == 'write' || n == 'multiedit' || n == 'notebookedit') return LucideIcons.pencil;
  if (n == 'grep' || n == 'glob' || n.contains('search')) return LucideIcons.search;
  if (n == 'agent' || n == 'task') return LucideIcons.bot;
  if (n.startsWith('web')) return LucideIcons.globe;
  if (n == 'plan') return LucideIcons.map;
  if (n == 'todos') return LucideIcons.listChecks;
  return LucideIcons.wrench;
}

/// Consecutive tool calls: one line each; tap one for its output. Long runs fold.
class ToolSteps extends StatefulWidget {
  final List<ChatItem> tools;
  final ChatItem? Function(ChatItem) resultFor;
  /// The call that is running right now (spinner), if any.
  final String? live;
  const ToolSteps({super.key, required this.tools, required this.resultFor, this.live});
  @override
  State<ToolSteps> createState() => _ToolStepsState();
}

class _ToolStepsState extends State<ToolSteps> {
  final _open = <String>{};
  bool _all = false;
  static const fold = 4;

  @override
  Widget build(BuildContext context) {
    final tools = widget.tools;
    final hidden = !_all && tools.length > fold + 1 ? tools.length - fold : 0;
    final shown = tools.sublist(hidden);
    final rows = <Widget>[
      if (hidden > 0)
        _Row(
          onTap: () => setState(() => _all = true),
          child: Row(children: [
            const Icon(LucideIcons.listCollapse, size: 16, color: C.t3),
            const SizedBox(width: 10),
            Expanded(child: Text('$hidden earlier steps', style: T.label)),
            const Icon(LucideIcons.chevronDown, size: 16, color: C.t3),
          ]),
        ),
      for (final t in shown) ..._tool(t),
    ];
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, r) in rows.indexed) ...[if (i > 0 && r is _Row) const Divider(height: 1, color: C.border), r],
      ]),
    );
  }

  List<Widget> _tool(ChatItem t) {
    final r = widget.resultFor(t);
    final open = _open.contains(t.id);
    final live = widget.live == t.tool;
    Widget? status;
    if (r != null) {
      status = Icon(r.ok ? LucideIcons.check : LucideIcons.x, size: 16, color: r.ok ? C.ok : C.failed);
    } else if (live) {
      status = const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: C.t2));
    }
    return [
      _Row(
        onTap: () => setState(() => open ? _open.remove(t.id) : _open.add(t.id)),
        semantics: '${t.name} ${t.title}${r == null ? '' : (r.ok ? ', done' : ', failed')}',
        child: Row(children: [
          Icon(toolIcon(t.name), size: 16, color: C.t3),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: t.name, style: const TextStyle(fontFamily: F.mono, fontSize: 13, fontWeight: FontWeight.w500, color: C.t2)),
                const TextSpan(text: '  '),
                TextSpan(text: t.title, style: const TextStyle(fontFamily: F.sans, fontSize: 14, color: C.t1)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (r?.add != null) ...[
            const SizedBox(width: 8),
            Text('+${r!.add}', style: const TextStyle(fontFamily: F.mono, fontSize: 12, color: C.ok)),
            const SizedBox(width: 4),
            Text('−${r.del ?? 0}', style: const TextStyle(fontFamily: F.mono, fontSize: 12, color: C.failed)),
          ],
          if (status != null) ...[const SizedBox(width: 10), status],
          const SizedBox(width: 8),
          Icon(open ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 16, color: C.t3),
        ]),
      ),
      if (open)
        Padding(
          padding: const EdgeInsets.fromLTRB(38, 0, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (t.detail.isNotEmpty && t.detail != t.title)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: SelectableText(t.detail, style: const TextStyle(fontFamily: F.mono, fontSize: 12, height: 18 / 12, color: C.t2))),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(color: C.canvas, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.sm)),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  r == null ? (live ? 'Running…' : 'No output yet.') : (r.preview.isEmpty ? '(no output)' : r.preview),
                  style: TextStyle(fontFamily: F.mono, fontSize: 12, height: 18 / 12, color: r != null && !r.ok ? const Color(0xFFF6A49B) : C.t2),
                ),
              ),
            ),
            if (r != null && r.lines > 4)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 0), minimumSize: const Size(44, 40), foregroundColor: C.t2),
                  onPressed: () => showOutput(context, '${t.name} · ${t.title}', r.text, r.cut),
                  child: Text('Show all ${r.lines} lines', style: T.label),
                ),
              ),
          ]),
        ),
    ];
  }
}

class _Row extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final String? semantics;
  const _Row({required this.child, required this.onTap, this.semantics});
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: semantics,
        child: InkWell(onTap: onTap, child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: child))),
      );
}

Future<void> showOutput(BuildContext context, String title, String text, bool cut) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        maxChildSize: .95,
        builder: (ctx, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(S.s4, 0, S.s4, S.s6), children: [
          Text(title, style: T.rowTitle),
          const SizedBox(height: S.s3),
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: SelectableText(text, style: const TextStyle(fontFamily: F.mono, fontSize: 12, height: 18 / 12, color: C.t1))),
          if (cut) const Padding(padding: EdgeInsets.only(top: S.s3), child: Text('Cut short here. The terminal has the rest.', style: T.caption)),
        ]),
      ),
    );

/// The plan from ExitPlanMode, as a readable block.
class PlanBlock extends StatelessWidget {
  final String plan;
  const PlanBlock(this.plan, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [Icon(LucideIcons.map, size: 16, color: C.t2), SizedBox(width: 8), Text('Plan', style: T.label)]),
          const SizedBox(height: S.s2),
          Markdown(plan),
        ]),
      );
}

/// An AskUserQuestion that is already answered: the question and what was picked.
class AskedRow extends StatelessWidget {
  final ChatItem item;
  final ChatItem? result;
  const AskedRow(this.item, this.result, {super.key});
  @override
  Widget build(BuildContext context) {
    final q = item.questions.map((q) => q.question).join(' · ');
    var a = result?.preview ?? '';
    final m = RegExp(r'"[^"]*"="([^"]*)"').allMatches(a).map((m) => m.group(1)).join(' · ');
    if (m.isNotEmpty) a = m;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 2), child: Icon(LucideIcons.messageCircleQuestion, size: 16, color: C.t3)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(q, style: T.secondary),
            if (a.isNotEmpty) ...[const SizedBox(height: 2), Text('→ $a', style: const TextStyle(fontFamily: F.sans, fontSize: 14, fontWeight: FontWeight.w500, color: C.t1))],
            if (result == null) const Text('Not answered', style: T.caption),
          ]),
        ),
      ]),
    );
  }
}

/// "Working · Running all tests" at the bottom while the agent runs.
class WorkingRow extends StatelessWidget {
  final String label;
  final Color color;
  const WorkingRow({super.key, required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        label: 'Working. $label',
        child: Row(children: [
          Pulse(color: color),
          const SizedBox(width: S.s2),
          const Text('Working', style: TextStyle(fontFamily: F.sans, fontSize: 14, fontWeight: FontWeight.w500, color: C.t1)),
          if (label.isNotEmpty) Expanded(child: Text(' · $label', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: F.sans, fontSize: 14, color: C.t2))) else const Spacer(),
        ]),
      );
}

/// Banner for offline / older Loft (Figma 8, 9).
class ChatBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? text;
  final String? action;
  final VoidCallback? onAction;
  const ChatBanner({super.key, required this.icon, required this.title, this.text, this.action, this.onAction, this.color = C.needs});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.borderStrong), borderRadius: BorderRadius.circular(R.md)),
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: S.s3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontFamily: F.sans, fontSize: 14, fontWeight: FontWeight.w500, color: C.t1)),
              if (text != null) Text(text!, style: T.secondary),
            ]),
          ),
          if (action != null) ...[const SizedBox(width: S.s2), Btn(action!, onTap: onAction, height: 40)],
        ]),
      );
}

/// Quick replies, the same three as desktop Loft. Only for a plain-text question.
const quickReplies = [
  ('Yes, go ahead', 'Yes, go ahead.'),
  ('No, stop there', 'No — stop there and wait.'),
  ('Explain more', 'Explain that in more detail first.'),
];

/// The needs-you card (Figma 2, 8, 10–15). Three shapes:
///  * an AskUserQuestion: the real options as rows, step by step for several
///    questions; single select = one tap; multi select = checkboxes + Submit;
///    "Other…" hands the answer to the reply bar.
///  * a permission or plan prompt: its numbered choices, one tap.
///  * a plain-text question: the question and the generic quick replies.
class PickerCard extends StatefulWidget {
  final PendingPrompt? prompt;
  /// The card's detail (what it asked), used for a plain-text question.
  final String detail;
  /// Skip the question's lead-in when the last message already says it.
  final bool showBody;
  final bool busy;
  /// Answer an AskUserQuestion (state is complete) or a permission (option number).
  final void Function(PickerState s) onAnswer;
  final void Function(int option, String label) onPermission;
  final void Function(String text) onQuickReply;
  /// "Other…" tapped for question [index]: the reply bar takes the text.
  final void Function(PickerState s, int index) onOther;
  final PickerState? state;
  const PickerCard({
    super.key,
    required this.prompt,
    required this.detail,
    required this.onAnswer,
    required this.onPermission,
    required this.onQuickReply,
    required this.onOther,
    this.state,
    this.showBody = true,
    this.busy = false,
  });
  @override
  State<PickerCard> createState() => _PickerCardState();
}

class _PickerCardState extends State<PickerCard> {
  PickerState? _own;
  PickerState? get _s => widget.state ?? _own;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(PickerCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final p = widget.prompt;
    if (widget.state == null && p != null && p.kind == PromptKind.question && p.questions.isNotEmpty && _own?.prompt.tool != p.tool) {
      _own = PickerState(p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    final children = <Widget>[];
    String label;
    IconData icon = LucideIcons.messageSquare;
    if (p != null && p.kind == PromptKind.question && p.questions.isNotEmpty && _s != null) {
      final s = _s!;
      final q = s.current;
      label = 'Needs you${q.header.isEmpty ? '' : ' · ${q.header}'}';
      if (s.many) {
        children.add(Row(children: [
          for (var i = 0; i < s.qs.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(child: Container(height: 3, decoration: BoxDecoration(color: i <= s.step ? C.needs : C.borderStrong, borderRadius: BorderRadius.circular(2)))),
          ],
        ]));
      }
      children.add(Text(q.question, style: T.question));
      if (q.multi) children.add(Text('Choose any.${s.step > 0 ? '  ${_soFar(s)}' : ''}', style: T.secondary));
      for (final (i, o) in q.options.indexed) {
        final on = q.multi ? (s.multi[s.step]?.contains(i) ?? false) : s.single[s.step] == i;
        children.add(OptionRow(
          label: o.label,
          description: o.description,
          multi: q.multi,
          selected: on,
          onTap: widget.busy
              ? null
              : () {
                  setState(() => s.pick(i));
                  if (!q.multi) _next(s);
                },
        ));
      }
      final other = s.other[s.step];
      children.add(OptionRow(
        label: other == null ? 'Other…' : 'Other: $other',
        description: other == null ? 'Type or say your own answer' : '',
        multi: q.multi && other != null,
        selected: other != null,
        other: other == null,
        onTap: widget.busy ? null : () => widget.onOther(s, s.step),
      ));
      if (q.multi || s.step > 0) {
        children.add(Row(children: [
          if (s.step > 0) ...[Btn('Back', onTap: widget.busy ? null : () => setState(() => s.step--)), const SizedBox(width: S.s2)],
          if (q.multi)
            Expanded(
              child: Btn(s.isLast ? (s.many ? 'Submit ${s.qs.length} answers' : 'Submit') : 'Next',
                  kind: BtnKind.primary, busy: widget.busy, onTap: s.answered(s.step) ? () => _next(s) : null),
            ),
        ]));
      }
      return _frame(label, icon, children, step: s.many ? '${s.step + 1} of ${s.qs.length}' : null);
    }
    if (p != null && p.kind == PromptKind.permission && p.options.isNotEmpty) {
      icon = p.isPlan ? LucideIcons.map : LucideIcons.shieldCheck;
      label = p.isPlan ? 'Needs you · Plan' : 'Needs you · Permission';
      children.add(Text(p.isPlan ? 'Start on this plan?' : (p.title.isEmpty ? 'Do you want to proceed?' : p.title), style: T.question));
      if (!p.isPlan && p.action.isNotEmpty) {
        children.add(Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(color: C.canvas, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.sm)),
          child: Text(p.action.replaceFirst(RegExp(r'^approve\s+'), ''), style: const TextStyle(fontFamily: F.mono, fontSize: 13, height: 20 / 13, color: C.t1)),
        ));
      }
      for (final (n, l) in p.options) {
        children.add(OptionRow(label: l, number: n, onTap: widget.busy ? null : () => widget.onPermission(n, l)));
      }
      return _frame(label, icon, children);
    }
    // Plain text: what it asked, then the generic quick replies.
    final ask = splitAsk(widget.detail.isEmpty ? 'It stopped and is waiting for you.' : widget.detail);
    if (widget.showBody && ask.body.isNotEmpty) children.add(Text.rich(inlineSpan(ask.body, T.body.copyWith(fontSize: 15, height: 22 / 15, color: C.t2))));
    if (ask.question.isNotEmpty) children.add(Text(ask.question, style: T.question));
    children.add(Wrap(spacing: S.s2, runSpacing: S.s2, children: [
      for (final (label, text) in quickReplies) Btn(label, height: 44, onTap: widget.busy ? null : () => widget.onQuickReply(text)),
    ]));
    return _frame('Needs you', icon, children);
  }

  String _soFar(PickerState s) {
    final parts = <String>[];
    for (var i = 0; i < s.step; i++) {
      if (!s.qs[i].multi && s.single[i] != null) parts.add('${s.qs[i].header.isEmpty ? 'Q${i + 1}' : s.qs[i].header}: ${s.qs[i].options[s.single[i]!].label}');
      if ((s.other[i] ?? '').isNotEmpty) parts.add('${s.qs[i].header}: ${s.other[i]}');
    }
    return parts.join(' · ');
  }

  void _next(PickerState s) {
    if (!s.answered(s.step)) return;
    if (!s.isLast) {
      setState(() => s.step++);
    } else if (s.complete) {
      widget.onAnswer(s);
    }
  }

  Widget _frame(String label, IconData icon, List<Widget> children, {String? step}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: C.surface,
          border: Border.all(color: C.needs.withValues(alpha: .55)),
          borderRadius: BorderRadius.circular(R.lg),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, size: 14, color: C.needs),
            const SizedBox(width: S.s2),
            Expanded(child: Text(label, style: const TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: C.needs))),
            if (step != null) Text(step, style: const TextStyle(fontFamily: F.mono, fontSize: 12, color: C.t2)),
          ]),
          for (final c in children) ...[const SizedBox(height: S.s3), c],
        ]),
      );
}

class OptionRow extends StatelessWidget {
  final String label, description;
  final bool multi, selected, other;
  final int? number;
  final VoidCallback? onTap;
  const OptionRow({super.key, required this.label, this.description = '', this.multi = false, this.selected = false, this.other = false, this.number, this.onTap});

  @override
  Widget build(BuildContext context) {
    Widget? lead;
    if (multi) {
      lead = Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(color: selected ? C.t1 : null, border: selected ? null : Border.all(color: C.t3, width: 1.5), borderRadius: BorderRadius.circular(5)),
        child: selected ? const Icon(LucideIcons.check, size: 14, color: C.canvas) : null,
      );
    } else if (number != null) {
      lead = Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(border: Border.all(color: C.borderStrong), borderRadius: BorderRadius.circular(6)),
        child: Text('$number', style: const TextStyle(fontFamily: F.mono, fontSize: 12, color: C.t2)),
      );
    }
    return Semantics(
      button: true,
      checked: multi ? selected : null,
      selected: !multi && selected,
      child: Material(
        color: selected ? C.selected : C.raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md), side: BorderSide(color: selected ? C.t3 : C.borderStrong)),
        child: InkWell(
          borderRadius: BorderRadius.circular(R.md),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(children: [
                if (lead != null) ...[lead, const SizedBox(width: 12)],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(label, style: T.button.copyWith(color: other ? C.t2 : C.t1)),
                    if (description.isNotEmpty) ...[const SizedBox(height: 2), Text(description, style: T.secondary)],
                  ]),
                ),
                if (!multi) ...[const SizedBox(width: 8), Icon(other ? LucideIcons.pencilLine : LucideIcons.cornerDownLeft, size: 16, color: C.t3)],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
