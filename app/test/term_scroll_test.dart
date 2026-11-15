import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loft/data/term_mouse.dart';
import 'package:xterm/xterm.dart';

/// The modes `claude attach` turns on (captured from a real attach):
/// alternate screen, any-motion mouse tracking, SGR reports.
const claudeModes = '\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h';

(Terminal, List<String>) attached() {
  final out = <String>[];
  final t = Terminal(maxLines: 100, mouseHandler: const LoftMouseHandler())..onOutput = out.add;
  t.write(claudeModes);
  return (t, out);
}

void main() {
  test('wheel reports use the standard codes 64/65 (Claude ignores 68/69)', () {
    final (t, out) = attached();
    t.mouseInput(TerminalMouseButton.wheelUp, TerminalMouseButtonState.down, const CellOffset(19, 9));
    t.mouseInput(TerminalMouseButton.wheelDown, TerminalMouseButtonState.down, const CellOffset(0, 0));
    expect(out, ['\x1b[<64;20;10M', '\x1b[<65;1;1M']);
  });

  test('wheel release is never reported', () {
    final (t, out) = attached();
    expect(t.mouseInput(TerminalMouseButton.wheelUp, TerminalMouseButtonState.up, const CellOffset(0, 0)), isFalse);
    expect(out, isEmpty);
  });

  test('clicks still go through the package handler', () {
    final (t, out) = attached();
    t.mouseInput(TerminalMouseButton.left, TerminalMouseButtonState.down, const CellOffset(4, 2));
    expect(out, ['\x1b[<0;5;3M']);
  });

  test('no mouse mode: nothing is sent', () {
    final out = <String>[];
    final t = Terminal(mouseHandler: const LoftMouseHandler())..onOutput = out.add;
    t.write('\x1b[?1049h');
    expect(t.mouseInput(TerminalMouseButton.wheelUp, TerminalMouseButtonState.down, const CellOffset(0, 0)), isFalse);
    expect(out, isEmpty);
  });

  test('normal (X10) report mode encodes 64 as a printable byte', () {
    final out = <String>[];
    final t = Terminal(mouseHandler: const LoftMouseHandler())..onOutput = out.add;
    t.write('\x1b[?1049h\x1b[?1000h');
    t.mouseInput(TerminalMouseButton.wheelUp, TerminalMouseButtonState.down, const CellOffset(0, 0));
    expect(out, ['\x1b[M${String.fromCharCode(96)}!!']);
  });

  testWidgets('dragging down on the full-screen terminal scrolls Claude up, never sends arrows', (tester) async {
    final (t, out) = attached();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 400, height: 600, child: TerminalView(t, simulateScroll: false))),
    ));
    await tester.pump();
    await tester.drag(find.byType(TerminalView), const Offset(0, 200));
    await tester.pumpAndSettle();
    final wheel = out.where((s) => s.startsWith('\x1b[<64;')).length;
    expect(wheel, greaterThan(3));
    expect(out.where((s) => s.startsWith('\x1b[<68;') || s == '\x1b[A' || s == '\x1b[B'), isEmpty);

    out.clear();
    await tester.drag(find.byType(TerminalView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(out.where((s) => s.startsWith('\x1b[<65;')).length, greaterThan(3));
  });
}
