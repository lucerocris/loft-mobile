import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/grouping.dart';
import '../data/models.dart';
import '../theme/tokens.dart';

/// The Loft mark: a house (the loft) with two windows, work blue and personal green.
class LoftMark extends StatelessWidget {
  final double size;
  final Color body, left, right;
  const LoftMark({super.key, this.size = 24, this.body = C.t1, this.left = C.work, this.right = C.personal});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _MarkPainter(body, left, right));
}

class _MarkPainter extends CustomPainter {
  final Color body, left, right;
  _MarkPainter(this.body, this.left, this.right);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64);
    final house = Path()
      ..moveTo(32, 7)
      ..lineTo(57, 27)
      ..lineTo(57, 51)
      ..cubicTo(57, 54.9, 53.9, 58, 50, 58)
      ..lineTo(14, 58)
      ..cubicTo(10.1, 58, 7, 54.9, 7, 51)
      ..lineTo(7, 27)
      ..close();
    canvas.drawPath(house, Paint()..color = body);
    canvas.drawPath(house, Paint()
      ..color = body
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeJoin = StrokeJoin.round);
    canvas.drawCircle(const Offset(22.5, 38), 7, Paint()..color = left);
    canvas.drawCircle(const Offset(41.5, 38), 7, Paint()..color = right);
  }

  @override
  bool shouldRepaint(_MarkPainter o) => o.body != body || o.left != left || o.right != right;
}

class Dot extends StatelessWidget {
  final Color color;
  final double size;
  final bool hollow;
  const Dot(this.color, {super.key, this.size = 8, this.hollow = false});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hollow ? null : color,
          border: hollow ? Border.all(color: color, width: 1.5) : null,
        ),
      );
}

/// 48 dp round icon button (app bars, keys).
class IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final double size;
  final Color color;
  const IconBtn(this.icon, {super.key, required this.onTap, required this.tooltip, this.size = 22, this.color = C.t1});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 48,
        height: 48,
        child: IconButton(
          onPressed: onTap,
          tooltip: tooltip,
          icon: Icon(icon, size: size, color: onTap == null ? C.t3 : color),
          style: IconButton.styleFrom(shape: const CircleBorder()),
        ),
      );
}

enum BtnKind { primary, secondary, quiet, danger }

/// Figma Button: primary (one per view), secondary, quiet, danger. 48 high on the phone.
class Btn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final BtnKind kind;
  final IconData? icon;
  final double height;
  final bool busy;
  const Btn(this.label, {super.key, required this.onTap, this.kind = BtnKind.secondary, this.icon, this.height = 48, this.busy = false});

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (kind) {
      BtnKind.primary => (C.primary, C.onPrimary, C.primary),
      BtnKind.secondary => (C.raised, C.t1, C.borderStrong),
      BtnKind.quiet => (Colors.transparent, C.t2, Colors.transparent),
      BtnKind.danger => (C.failed, C.onPrimary, C.failed),
    };
    final disabled = onTap == null;
    return Opacity(
      opacity: disabled && kind == BtnKind.primary ? .45 : 1,
      child: Material(
        color: disabled && kind != BtnKind.primary ? C.surface : bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md), side: BorderSide(color: disabled && kind != BtnKind.primary ? C.border : border)),
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(R.md),
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.s4),
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                if (busy)
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                else if (icon != null)
                  Icon(icon, size: 18, color: disabled ? C.t3 : fg),
                if (busy || icon != null) const SizedBox(width: 6),
                Text(label, style: T.button.copyWith(color: disabled ? C.t3 : fg)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// How a group or value is marked: account = round dot, project = rounded
/// square, Unsorted / unknown login = hollow square.
class MarkDot extends StatelessWidget {
  final Mark mark;
  final Color? color;
  final double size;
  const MarkDot(this.mark, this.color, {super.key, this.size = 8});
  @override
  Widget build(BuildContext context) {
    if (mark == Mark.none) return const SizedBox.shrink();
    final c = color ?? C.t3;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: mark == Mark.dot ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: mark == Mark.dot ? null : BorderRadius.circular(size > 10 ? 4 : 2.5),
        color: mark == Mark.hollow ? null : c,
        border: mark == Mark.hollow ? Border.all(color: c, width: 1.5) : null,
      ),
    );
  }
}

/// A pill chip for the inbox toolbar: Group by and the filter values.
class PillChip extends StatelessWidget {
  final String label;
  final bool selected;
  final int? count;
  final Widget? lead;
  final Widget? trail;
  final VoidCallback onTap;
  const PillChip({super.key, required this.label, required this.onTap, this.selected = false, this.count, this.lead, this.trail});
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? C.selected : C.raised,
          shape: StadiumBorder(side: BorderSide(color: selected ? C.borderStrong : C.border)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: SizedBox(
              height: 40,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (lead != null) ...[lead!, const SizedBox(width: S.s2)],
                  Text(label, style: TextStyle(fontFamily: F.sans, fontSize: 14, fontWeight: FontWeight.w500, color: selected ? C.t1 : C.t2)),
                  if (count != null) ...[const SizedBox(width: S.s2), Text('$count', style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3))],
                  if (trail != null) ...[const SizedBox(width: 6), trail!],
                ]),
              ),
            ),
          ),
        ),
      );
}

/// Group by chip + the active dimension's filter chips, scrolling sideways.
class InboxToolbar extends StatelessWidget {
  final GroupBy groupBy;
  final List<FilterOption> options;
  final String filter;
  final VoidCallback onGroupBy;
  final ValueChanged<String> onFilter;
  const InboxToolbar({super.key, required this.groupBy, required this.options, required this.filter, required this.onGroupBy, required this.onFilter});
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(children: [
          PillChip(
            label: 'By ${groupByLabel(groupBy).toLowerCase()}',
            lead: const Icon(LucideIcons.listFilter, size: 16, color: C.t2),
            trail: const Icon(LucideIcons.chevronDown, size: 16, color: C.t3),
            onTap: onGroupBy,
          ),
          if (options.isNotEmpty) Container(width: 1, height: 24, margin: const EdgeInsets.symmetric(horizontal: S.s2), color: C.borderStrong),
          for (final o in options) ...[
            PillChip(
              label: o.label,
              count: o.count,
              selected: o.key == filter,
              lead: o.mark == Mark.none ? null : MarkDot(o.mark, o.color == null ? null : Color(o.color!)),
              onTap: () => onFilter(o.key),
            ),
            const SizedBox(width: S.s2),
          ],
        ]),
      );
}

/// Figma "Usage meter": a 4 px bar and a mono caption; amber at 85%.
class UsageMeter extends StatelessWidget {
  final String label;
  final UsageWindow u;
  final Color color;
  const UsageMeter({super.key, required this.label, required this.u, required this.color});

  @override
  Widget build(BuildContext context) {
    final fill = u.hot ? C.needs : color;
    String pct(String s) => UsageWindow.pct(s) == null ? s : '$s%';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(R.full),
        child: SizedBox(
          height: 4,
          child: Stack(children: [
            Container(color: C.selected),
            FractionallySizedBox(widthFactor: u.fill, child: Container(decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(R.full)))),
          ]),
        ),
      ),
      const SizedBox(height: 5),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text('$label  5h ${pct(u.five)} · 7d ${pct(u.seven)}', maxLines: 1, style: T.mono12.copyWith(color: u.hot ? C.needs : C.t3)),
      ),
    ]);
  }
}

/// One meter per account, two to a row; labels and colors from the laptop's account list.
class UsageStrip extends StatelessWidget {
  final Snapshot snap;
  const UsageStrip({super.key, required this.snap});
  @override
  Widget build(BuildContext context) {
    final accs = snap.accounts;
    if (accs.isEmpty) return const SizedBox.shrink();
    Widget meter(Account a) => UsageMeter(label: a.label, u: snap.usageOf(a.id), color: Color(a.color));
    return Padding(
      padding: const EdgeInsets.all(S.s1),
      child: Column(children: [
        for (var i = 0; i < accs.length; i += 2) ...[
          if (i > 0) const SizedBox(height: S.s3),
          Row(children: [
            Expanded(child: meter(accs[i])),
            if (i + 1 < accs.length) ...[const SizedBox(width: S.s4), Expanded(child: meter(accs[i + 1]))] else if (accs.length > 1) ...[
              const SizedBox(width: S.s4),
              const Spacer(),
            ],
          ]),
        ],
      ]),
    );
  }
}

/// Figma "Agent item": status dot, title + one line, age + account dot.
class AgentItem extends StatelessWidget {
  final AgentCard card;
  final VoidCallback onTap;
  /// The card's account color; the trailing dot shows only with [showAccount].
  final Color? accountColor;
  final bool showAccount;
  final String accountLabel;
  /// A project tag before the line (when the inbox isn't grouped by project).
  final Project? project;
  const AgentItem({super.key, required this.card, required this.onTap, this.accountColor, this.showAccount = false, this.accountLabel = '', this.project});

  @override
  Widget build(BuildContext context) {
    final c = card;
    final Widget status = c.failed
        ? const Dot(C.failed)
        : switch (c.col) {
            Col.needs => const Dot(C.needs),
            Col.running => _Pulse(color: accountColor ?? C.work),
            Col.todo => const Dot(C.t3, hollow: true),
            Col.done => Dot(C.t3.withValues(alpha: .6)),
          };
    final lineColor = c.failed ? C.failed : (c.col == Col.needs ? C.t2 : C.t3);
    return Semantics(
      button: true,
      label: [c.name, if (showAccount && accountLabel.isNotEmpty) accountLabel, ?project?.name, c.col.name].join(', '),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(children: [
            status,
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  if (c.pinned) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(LucideIcons.pin, size: 13, color: C.t3)),
                  Expanded(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.rowTitle.copyWith(color: c.col == Col.done ? C.t2 : C.t1))),
                ]),
                const SizedBox(height: 1),
                Row(children: [
                  if (project != null) ...[
                    MarkDot(Mark.square, Color(project!.color), size: 6),
                    const SizedBox(width: 5),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(project!.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.secondary.copyWith(color: C.t2)),
                    ),
                    Text(' · ', style: T.secondary.copyWith(color: C.t3)),
                  ],
                  Expanded(child: Text(c.line.replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.secondary.copyWith(color: lineColor))),
                ]),
              ]),
            ),
            const SizedBox(width: 12),
            Text(ago(c.updated), style: T.mono12),
            if (showAccount) ...[const SizedBox(width: 6), Dot(accountColor ?? C.t3, size: 6, hollow: accountColor == null)],
          ]),
        ),
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  final Color color;
  const _Pulse({required this.color});
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return Dot(widget.color);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = (_c.value / .7).clamp(0.0, 1.0);
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color, boxShadow: [
            BoxShadow(color: widget.color.withValues(alpha: .5 * (1 - t)), spreadRadius: 5 * t),
          ]),
        );
      },
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final bool alert;
  final Widget? trailing;
  final Widget? lead;
  /// "· 2 need you" after the count (grouped views).
  final int needs;
  const SectionHeader(this.label, this.count, {super.key, this.alert = false, this.trailing, this.lead, this.needs = 0});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
        child: Row(children: [
          Expanded(
            child: Row(children: [
              if (lead != null) ...[lead!, const SizedBox(width: S.s2)],
              Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.label.copyWith(color: alert ? C.needs : C.t2))),
              const SizedBox(width: S.s2),
              Text('$count', style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3)),
              if (needs > 0) Text('  · $needs need${needs == 1 ? 's' : ''} you', style: T.label.copyWith(color: C.needs)),
            ]),
          ),
          ?trailing,
        ]),
      );
}

/// Level bars for the "Listening" header (Figma Voice dock).
class LevelBars extends StatelessWidget {
  final List<double> levels;
  final Color color;
  const LevelBars(this.levels, {super.key, this.color = C.t1});
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 24,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final l in levels)
            Container(
              width: 3,
              height: 4 + 20 * l,
              margin: const EdgeInsets.only(right: 3),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
            ),
        ]),
      );
}

String clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// A confirm dialog for Stop and Archive (danger actions always confirm).
Future<bool> confirmDanger(BuildContext context, {required String title, required String body, required String action}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        Btn('Cancel', onTap: () => Navigator.pop(ctx, false), kind: BtnKind.quiet, height: 44),
        Btn(action, onTap: () => Navigator.pop(ctx, true), kind: BtnKind.danger, height: 44),
      ],
    ),
  );
  return ok == true;
}

void toast(BuildContext context, String msg, {bool error = false, SnackBarAction? action, Duration? duration}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(msg, style: TextStyle(fontFamily: F.sans, fontSize: 14, color: error ? C.failed : C.t1)),
    action: action,
    duration: duration ?? Duration(milliseconds: error ? 5000 : 2600),
  ));
}
