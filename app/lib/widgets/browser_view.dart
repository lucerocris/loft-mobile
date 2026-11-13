import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/browser.dart';
import '../state/browser_session.dart';
import '../theme/tokens.dart';
import 'common.dart';

/// The live page: the latest frame, fitted and top-aligned. Tap = click,
/// drag = scroll (with a little momentum), long-press then move = mouse drag
/// (select text, drag a slider).
class BrowserPicture extends StatefulWidget {
  final BrowserSession session;
  const BrowserPicture({super.key, required this.session});
  @override
  State<BrowserPicture> createState() => _BrowserPictureState();
}

class _BrowserPictureState extends State<BrowserPicture> {
  Rect _pic = Rect.zero;
  Offset _wheel = Offset.zero;
  Offset _at = Offset.zero;
  Timer? _flush, _fling;
  bool _dragging = false;

  BrowserSession get s => widget.session;

  @override
  void dispose() {
    _flush?.cancel();
    _fling?.cancel();
    super.dispose();
  }

  Offset? _page(Offset local, {bool clamp = false}) => toPageFraction(local, _pic, clamp: clamp);

  void _queueWheel(Offset local, Offset drag) {
    final at = _page(local, clamp: true);
    if (at == null) return;
    _at = at;
    _wheel += wheelFor(drag, _pic, s.pageWidth);
    _flush ??= Timer(const Duration(milliseconds: 32), () {
      _flush = null;
      final w = _wheel;
      _wheel = Offset.zero;
      s.scroll(_at, w);
    });
  }

  void _startFling(Offset local, Velocity v) {
    var vel = v.pixelsPerSecond;
    if (vel.distance < 300) return;
    _fling?.cancel();
    var steps = 0;
    _fling = Timer.periodic(const Duration(milliseconds: 32), (t) {
      vel = vel * .85;
      if (++steps > 20 || vel.distance < 60) return t.cancel();
      _queueWheel(local, vel * .032);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        return ListenableBuilder(
          listenable: s,
          builder: (context, _) {
            final img = s.frame;
            _pic = img == null ? Rect.zero : fitPicture(box.biggest, Size(img.width.toDouble(), img.height.toDouble()));
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => _fling?.cancel(),
              onTapUp: (d) {
                final p = _page(d.localPosition);
                if (p != null) s.tap(p);
              },
              onPanStart: (_) => _fling?.cancel(),
              onPanUpdate: (d) => _queueWheel(d.localPosition, d.delta),
              onPanEnd: (d) => _startFling(_pic.center, d.velocity),
              onLongPressStart: (d) {
                final p = _page(d.localPosition);
                if (p == null) return;
                HapticFeedback.selectionClick();
                _dragging = true;
                s.send(BrowserMsg.mouse('mouseMoved', p));
                s.send(BrowserMsg.mouse('mousePressed', p));
              },
              onLongPressMoveUpdate: (d) {
                final p = _page(d.localPosition, clamp: true);
                if (_dragging && p != null) s.send(BrowserMsg.mouse('mouseMoved', p));
              },
              onLongPressEnd: (d) {
                final p = _page(d.localPosition, clamp: true);
                if (_dragging && p != null) s.send(BrowserMsg.mouse('mouseReleased', p));
                _dragging = false;
              },
              child: Stack(children: [
                if (img != null)
                  Positioned.fromRect(
                    rect: _pic,
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(border: Border.all(color: C.border)),
                      child: RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                    ),
                  ),
              ]),
            );
          },
        );
      });
}

/// The whole viewer: address bar (back, reload, address, mobile/desktop),
/// the live picture with its states, and the keyboard row.
class BrowserViewer extends StatefulWidget {
  final BrowserSession session;
  const BrowserViewer({super.key, required this.session});
  @override
  State<BrowserViewer> createState() => _BrowserViewerState();
}

class _BrowserViewerState extends State<BrowserViewer> {
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  final _typing = TextEditingController();
  final _typingFocus = FocusNode();
  String _typed = '';
  bool _keyboard = false;
  StreamSubscription? _toasts;

  BrowserSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    s.addListener(_sync);
    _toasts = s.toasts.listen((t) {
      if (mounted && t.text.isNotEmpty) toast(context, t.text, error: t.error);
    });
    _typing.addListener(_onTyping);
    _sync();
  }

  @override
  void dispose() {
    s.removeListener(_sync);
    _toasts?.cancel();
    _address.dispose();
    _addressFocus.dispose();
    _typing.dispose();
    _typingFocus.dispose();
    super.dispose();
  }

  void _sync() {
    if (!_addressFocus.hasFocus) {
      final u = shortUrl(s.url);
      if (_address.text != u) _address.text = u;
    }
  }

  void _onTyping() {
    final now = _typing.text;
    if (now == _typed) return;
    s.typeDiff(_typed, now);
    _typed = now;
  }

  void _clearTyping() {
    _typed = '';
    _typing.clear();
  }

  void _key(String k) {
    HapticFeedback.selectionClick();
    s.send(BrowserMsg.key(k));
  }

  void _toggleKeyboard() {
    setState(() => _keyboard = !_keyboard);
    if (_keyboard) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _typingFocus.requestFocus());
    } else {
      _typingFocus.unfocus();
      _clearTyping();
    }
  }

  void _showErrors() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .7),
            child: ListView(padding: const EdgeInsets.fromLTRB(S.s5, 0, S.s5, S.s4), shrinkWrap: true, children: [
              const Text('Page errors', style: TextStyle(fontFamily: F.sans, fontSize: 17, fontWeight: FontWeight.w600, color: C.t1)),
              const SizedBox(height: S.s3),
              for (final e in s.errors.reversed) Padding(padding: const EdgeInsets.only(bottom: S.s2), child: Text(e, style: T.mono12.copyWith(color: C.failed))),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final live = s.status == BrowserStatus.live;
          return Column(children: [
            // Address bar
            Padding(
              padding: const EdgeInsets.fromLTRB(S.s1, 0, S.s2, S.s2),
              child: Row(children: [
                IconBtn(LucideIcons.arrowLeft, tooltip: 'Page back', size: 20, onTap: live ? () => s.send(BrowserMsg.back()) : null),
                IconBtn(LucideIcons.rotateCw, tooltip: 'Reload', size: 20, onTap: live ? () => s.send(BrowserMsg.reload()) : null),
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: TextField(
                      controller: _address,
                      focusNode: _addressFocus,
                      enabled: live,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: const TextStyle(fontFamily: F.mono, fontSize: 13, color: C.t1),
                      onTap: () => _address.selection = TextSelection(baseOffset: 0, extentOffset: _address.text.length),
                      onSubmitted: (v) {
                        s.navigate(v);
                        _addressFocus.unfocus();
                      },
                      decoration: InputDecoration(
                        hintText: 'Address',
                        hintStyle: const TextStyle(fontFamily: F.sans, fontSize: 14, color: C.t3),
                        filled: true,
                        fillColor: C.raised,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.border)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.border)),
                        disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.border)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.t2)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: S.s1),
                IconBtn(s.mobile ? LucideIcons.smartphone : LucideIcons.monitor,
                    tooltip: s.mobile ? 'Phone-sized page (tap for desktop)' : 'Desktop-sized page (tap for phone)', size: 20, onTap: live ? () => s.setMobile(!s.mobile) : null),
              ]),
            ),
            const Divider(height: 1, color: C.border),
            // Picture and its states
            Expanded(
              child: Container(
                color: C.canvas,
                padding: const EdgeInsets.fromLTRB(S.s2, S.s2, S.s2, 0),
                child: Stack(children: [
                  Positioned.fill(child: BrowserPicture(session: s)),
                  if (s.status != BrowserStatus.live || s.frame == null) Positioned.fill(child: _state()),
                ]),
              ),
            ),
            // Keyboard row
            Container(
              decoration: const BoxDecoration(color: C.surface, border: Border(top: BorderSide(color: C.border))),
              padding: const EdgeInsets.fromLTRB(12, S.s2, 12, S.s2),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_keyboard)
                  Padding(
                    padding: const EdgeInsets.only(bottom: S.s2),
                    child: TextField(
                      controller: _typing,
                      focusNode: _typingFocus,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.send,
                      style: const TextStyle(fontFamily: F.sans, fontSize: 15, color: C.t1),
                      onSubmitted: (_) {
                        _key('Enter');
                        _clearTyping();
                        _typingFocus.requestFocus();
                      },
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Types into the page as you go',
                        hintStyle: const TextStyle(fontFamily: F.sans, fontSize: 15, color: C.t3),
                        filled: true,
                        fillColor: C.raised,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        suffixIcon: IconButton(tooltip: 'Clear (keeps the page)', icon: const Icon(LucideIcons.eraser, size: 16, color: C.t3), onPressed: _clearTyping),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.border)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.border)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.t2)),
                      ),
                    ),
                  ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    BrowserKey(icon: LucideIcons.keyboard, label: _keyboard ? 'Hide keyboard' : 'Keyboard', selected: _keyboard, onTap: live ? _toggleKeyboard : null),
                    BrowserKey(icon: LucideIcons.cornerDownLeft, label: 'Enter', onTap: live ? () => _key('Enter') : null),
                    BrowserKey(icon: LucideIcons.delete, label: 'Backspace', onTap: live ? () => _key('Backspace') : null),
                    BrowserKey(text: 'Tab', label: 'Tab', onTap: live ? () => _key('Tab') : null),
                    BrowserKey(text: 'Esc', label: 'Escape', onTap: live ? () => _key('Escape') : null),
                    BrowserKey(icon: LucideIcons.arrowUp, label: 'Up', onTap: live ? () => _key('ArrowUp') : null),
                    BrowserKey(icon: LucideIcons.arrowDown, label: 'Down', onTap: live ? () => _key('ArrowDown') : null),
                    BrowserKey(icon: LucideIcons.arrowLeft, label: 'Left', onTap: live ? () => _key('ArrowLeft') : null),
                    BrowserKey(icon: LucideIcons.arrowRight, label: 'Right', onTap: live ? () => _key('ArrowRight') : null),
                    if (s.errors.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: S.s1),
                        child: PillChip(label: '${s.errors.length} ${s.errors.length == 1 ? 'error' : 'errors'}', lead: const Dot(C.failed, size: 6), onTap: _showErrors),
                      ),
                  ]),
                ),
              ]),
            ),
          ]);
        },
      );

  Widget _state() {
    final (IconData? icon, String text, String? action) = switch (s.status) {
      BrowserStatus.connecting => (null, 'Opening the browser…', null),
      BrowserStatus.live => (null, 'Waiting for the page…', null),
      BrowserStatus.refused => (LucideIcons.monitorOff, s.message ?? 'Not available from the phone.', 'Try again'),
      BrowserStatus.closed => (LucideIcons.unplug, s.message ?? 'The browser closed.', 'Reconnect'),
    };
    return Container(
      color: C.canvas.withValues(alpha: .92),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(S.s6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (icon == null) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) else Icon(icon, size: 28, color: C.t3),
        const SizedBox(height: S.s3),
        Text(text, textAlign: TextAlign.center, style: T.secondary),
        if (action != null) ...[const SizedBox(height: S.s4), Btn(action, icon: LucideIcons.refreshCw, height: 44, onTap: s.start)],
      ]),
    );
  }
}

/// A key on the browser's keys row (same look as the terminal's).
class BrowserKey extends StatelessWidget {
  final IconData? icon;
  final String? text;
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  const BrowserKey({super.key, this.icon, this.text, required this.label, this.selected = false, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final fg = onTap == null ? C.t3 : C.t1;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: selected ? C.selected : C.raised,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sm), side: BorderSide(color: selected ? C.t2 : C.borderStrong)),
            child: InkWell(
              borderRadius: BorderRadius.circular(R.sm),
              onTap: onTap,
              child: SizedBox(
                height: 44,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 44),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: text == null ? 0 : 14),
                    child: Center(
                      widthFactor: 1,
                      child: icon != null ? Icon(icon, size: 18, color: fg) : Text(text!, style: TextStyle(fontFamily: F.mono, fontSize: 13, color: fg)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
