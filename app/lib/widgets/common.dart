import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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

/// All / Work / Personal (Figma "Account filter").
class AccountFilter extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const AccountFilter({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget seg(String v, String label, Color? dot) {
      final on = value == v;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          child: InkWell(
            onTap: () => onChanged(v),
            child: Container(
              color: on ? C.selected : Colors.transparent,
              alignment: Alignment.center,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (dot != null) ...[Dot(dot), const SizedBox(width: S.s2)],
                Text(label, style: TextStyle(fontFamily: F.sans, fontSize: 14, fontWeight: FontWeight.w500, color: on ? C.t1 : C.t2)),
              ]),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(R.full), border: Border.all(color: C.borderStrong)),
      child: Row(children: [seg('', 'All', null), seg('work', 'Work', C.work), seg('personal', 'Personal', C.personal)]),
    );
  }
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

class UsageStrip extends StatelessWidget {
  final Snapshot snap;
  const UsageStrip({super.key, required this.snap});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(S.s1),
        child: Row(children: [
          Expanded(child: UsageMeter(label: 'Work', u: snap.work, color: C.work)),
          const SizedBox(width: S.s4),
          Expanded(child: UsageMeter(label: 'Personal', u: snap.personal, color: C.personal)),
        ]),
      );
}

/// Figma "Agent item": status dot, title + one line, age + account dot.
class AgentItem extends StatelessWidget {
  final AgentCard card;
  final VoidCallback onTap;
  const AgentItem({super.key, required this.card, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = card;
    final Widget status = c.failed
        ? const Dot(C.failed)
        : switch (c.col) {
            Col.needs => const Dot(C.needs),
            Col.running => _Pulse(color: C.account(c.work)),
            Col.todo => const Dot(C.t3, hollow: true),
            Col.done => Dot(C.t3.withValues(alpha: .6)),
          };
    final lineColor = c.failed ? C.failed : (c.col == Col.needs ? C.t2 : C.t3);
    return Semantics(
      button: true,
      label: '${c.name}, ${c.accountLabel}, ${c.col.name}',
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
                Text(c.line.replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.secondary.copyWith(color: lineColor)),
              ]),
            ),
            const SizedBox(width: 12),
            Text(ago(c.updated), style: T.mono12),
            const SizedBox(width: 6),
            Dot(C.account(c.work), size: 6),
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
  const SectionHeader(this.label, this.count, {super.key, this.alert = false, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
        child: Row(children: [
          Text(label, style: T.label.copyWith(color: alert ? C.needs : C.t2)),
          const SizedBox(width: S.s2),
          Text('$count', style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3)),
          const Spacer(),
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
