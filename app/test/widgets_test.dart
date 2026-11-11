import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loft/data/models.dart';
import 'package:loft/theme/theme.dart';
import 'package:loft/voice/voice_controller.dart';
import 'package:loft/widgets/common.dart';
import 'package:loft/widgets/voice_dock.dart';

Widget wrap(Widget w) => MaterialApp(theme: loftTheme(), home: Scaffold(body: w));

void main() {
  final snap = Snapshot.fromJson((jsonDecode(File('test/fixtures/state.json').readAsStringSync()) as Map).cast<String, dynamic>());

  testWidgets('agent item shows title, line and age', (t) async {
    var tapped = false;
    await t.pumpWidget(wrap(AgentItem(card: snap.byId('a1b2c3d4')!, onTap: () => tapped = true)));
    expect(find.text('Violations · SOP v2.2 diff'), findsOneWidget);
    expect(find.textContaining('Start steps 0 and 1?'), findsOneWidget);
    await t.tap(find.byType(AgentItem));
    expect(tapped, isTrue);
  });

  testWidgets('account filter reports the picked account', (t) async {
    String? picked;
    await t.pumpWidget(wrap(AccountFilter(value: '', onChanged: (v) => picked = v)));
    await t.tap(find.text('Personal'));
    expect(picked, 'personal');
  });

  testWidgets('usage meter turns amber at 85%', (t) async {
    await t.pumpWidget(wrap(UsageStrip(snap: snap)));
    final personal = t.widget<Text>(find.textContaining('Personal  5h'));
    expect(personal.style!.color, const Color(0xFFF2B544));
  });

  test('level meter history can scroll (regression: fixed-length list)', () {
    final v = VoiceController(client: () => null, laptopReachable: () => true);
    expect(v.levels.length, 20);
    v.levels
      ..removeAt(0)
      ..add(.5);
    expect(v.levels.last, .5);
  });

  testWidgets('voice dock: idle, then ready with text and the send button', (t) async {
    final voice = VoiceController(client: () => null, laptopReachable: () => true);
    final field = TextEditingController();
    var sent = false;
    await t.pumpWidget(wrap(Align(
      alignment: Alignment.bottomCenter,
      child: VoiceDock(voice: voice, field: field, focus: FocusNode(), onSend: () => sent = true, onTranscript: (_) async {}),
    )));
    expect(find.text('Reply, or hold the mic'), findsOneWidget);
    expect(find.text('Hold to talk · tap to keep listening'), findsOneWidget);
    await t.tap(find.byTooltip('Send'));
    expect(sent, isFalse); // disabled while empty
    field.text = 'go ahead with 0 and 1';
    await t.pump();
    expect(find.text('Tap send, or end with "send it" next time'), findsOneWidget);
    await t.tap(find.byTooltip('Send'));
    expect(sent, isTrue);
  });

  testWidgets('voice dock shows the phone-speech state when the laptop is unreachable', (t) async {
    final voice = VoiceController(client: () => null, laptopReachable: () => false);
    await t.pumpWidget(wrap(Align(
      alignment: Alignment.bottomCenter,
      child: VoiceDock(voice: voice, field: TextEditingController(), focus: FocusNode(), laptopReachable: false, onSend: () {}, onTranscript: (_) async {}),
    )));
    expect(find.text('Phone speech · fedora unreachable, check names'), findsOneWidget);
  });

  testWidgets('"send it" at the end fires after the Undo window; Undo cancels', (t) async {
    final field = TextEditingController();
    var fired = 0;
    await t.pumpWidget(wrap(Builder(builder: (ctx) {
      return Column(children: [
        TextButton(onPressed: () => deliverTranscript(ctx, field, 'Ship the fix, send it.', go: () => fired++, goLabel: 'Sending'), child: const Text('a')),
        TextButton(onPressed: () => deliverTranscript(ctx, field, 'and the docs. Send it', go: () => fired++, goLabel: 'Sending'), child: const Text('b')),
      ]);
    })));
    await t.tap(find.text('a'));
    await t.pump();
    expect(field.text, 'Ship the fix');
    await t.pump(const Duration(milliseconds: 2100));
    expect(fired, 1);
    await t.pumpAndSettle();
    await t.tap(find.text('b'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(field.text, 'Ship the fix and the docs');
    t.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed(); // the snackbar's Undo
    await t.pump();
    await t.pump(const Duration(seconds: 3));
    expect(fired, 1);
  });
}
