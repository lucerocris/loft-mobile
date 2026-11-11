import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loft/data/chat.dart';
import 'package:loft/data/loft_client.dart';
import 'package:loft/data/models.dart';
import 'package:loft/data/pairing.dart';
import 'package:loft/screens/chat_screen.dart';
import 'package:loft/state/conn.dart';
import 'package:loft/theme/theme.dart';
import 'package:loft/widgets/chat_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The fixture is Loft's generic test session (cagents tests/fixtures/chat_session.jsonl)
/// as GET /messages returns it, waiting on an AskUserQuestion.
final messagesJson = File('test/fixtures/messages.json').readAsStringSync();
ChatPage page0() => ChatPage.fromJson((jsonDecode(messagesJson) as Map).cast<String, dynamic>());

ChatItem it(String id, ChatKind k, {String text = '', String tool = '', String forTool = '', String name = 'Bash', String title = 't'}) =>
    ChatItem(id: id, kind: k, text: text, tool: tool, forTool: forTool, name: name, title: title);

Widget wrap(Widget w) => MaterialApp(theme: loftTheme(), home: Scaffold(body: SingleChildScrollView(child: w)));

const q1 = ChatQuestion(question: 'Pick a crust', header: 'Crust', options: [ChatOption('Thin', 'Crisp'), ChatOption('Thick', 'Soft')]);
const q2 = ChatQuestion(question: 'Pick toppings', header: 'Toppings', multi: true, options: [ChatOption('Cheese'), ChatOption('Olives'), ChatOption('Basil')]);

void main() {
  group('page and log', () {
    test('parses the server page', () {
      final p = page0();
      expect(p.items.length, 16);
      expect(p.state, 'needs');
      expect(p.prompt!.kind, PromptKind.question);
      expect(p.prompt!.tool, 'toolu_ask1');
      expect(p.prompt!.questions.single.options.first.label, 'Yes, add it');
      final edit = p.items.firstWhere((i) => i.kind == ChatKind.result && i.forTool == 'toolu_edit1');
      expect((edit.add, edit.del), (3, 1));
    });

    test('older servers: pending.question alone still gives a picker', () {
      final j = (jsonDecode(messagesJson) as Map).cast<String, dynamic>();
      (j['pending'] as Map).remove('prompt');
      expect(ChatPage.fromJson(j).prompt!.tool, 'toolu_ask1');
    });

    test('permission prompts parse', () {
      final p = PendingPrompt.fromJson({
        'kind': 'permission', 'tool': 'toolu_p', 'title': 'Do you want to proceed?', 'action': 'approve Bash: npm test',
        'options': [{'n': 1, 'label': 'Yes'}, {'n': 2, 'label': 'No'}],
      })!;
      expect(p.options, [(1, 'Yes'), (2, 'No')]);
      expect(p.isPlan, isFalse);
      expect(PendingPrompt.fromJson({'kind': 'permission', 'tool': 'x', 'action': 'approve plan', 'options': []})!.isPlan, isTrue);
    });

    test('rows group tool calls and keep results aside', () {
      final log = ChatLog()..apply(page0());
      final rows = log.rows();
      expect(rows.whereType<ToolsRow>().map((r) => r.tools.length).toList(), [3, 1]);
      expect(rows.first, isA<MsgRow>());
      final firstTools = rows.whereType<ToolsRow>().first.tools;
      expect(log.resultFor(firstTools.first)!.ok, isFalse);
      expect(rows.whereType<MsgRow>().where((r) => r.item.kind == ChatKind.question).length, 1);
    });

    test('new items append; a late result attaches to its call; locals give way', () {
      final log = ChatLog()
        ..apply(ChatPage(items: [it('u1', ChatKind.user, text: 'go'), it('t1', ChatKind.tool, tool: 'x1')], cursor: 100, session: 's'));
      expect(log.openTool!.tool, 'x1');
      log.addLocal('next please');
      log.apply(ChatPage(items: [it('r1', ChatKind.result, forTool: 'x1'), it('u2', ChatKind.user, text: 'next please')], cursor: 180, start: 100, session: 's'));
      expect(log.items.map((i) => i.id), ['u1', 't1', 'u2']);
      expect(log.openTool, isNull);
      expect(log.cursor, 180);
      expect(log.start, 0, reason: 'a poll does not move the start');
    });

    test('older pages prepend; a new session starts over', () {
      final log = ChatLog()..apply(ChatPage(items: [it('b', ChatKind.user, text: 'b')], cursor: 50, start: 20, more: true, session: 's'));
      log.apply(ChatPage(items: [it('a', ChatKind.user, text: 'a')], start: 0, more: false, session: 's'), older: true);
      expect(log.items.map((i) => i.id), ['a', 'b']);
      expect(log.more, isFalse);
      log.apply(ChatPage(items: [it('z', ChatKind.user, text: 'z')], cursor: 10, session: 'other'));
      expect(log.items.map((i) => i.id), ['z']);
    });
  });

  group('markdown', () {
    test('blocks', () {
      final b = parseMarkdown('# Title\n\nFixed it.\nTwo lines.\n\n```ts\nconst a = 1;\n```\n- one\n- two\n\n1. first\n2. second\n> quoted\n\n---\n| a | b |\n|---|---|');
      expect(b.map((x) => x.runtimeType.toString()).toList(), ['MdHeading', 'MdPara', 'MdCode', 'MdList', 'MdList', 'MdQuote', 'MdRule', 'MdCode']);
      expect((b[2] as MdCode).lang, 'ts');
      expect((b[2] as MdCode).code, 'const a = 1;');
      expect((b[4] as MdList).ordered, isTrue);
      expect((b[7] as MdCode).lang, 'table');
    });

    test('inline', () {
      expect(parseInline('Use `roundTotal` **now**, see [docs](https://x.y) and *this*; snake_case_stays').map((s) => '$s').toList(), [
        'plain:Use ',
        'code:roundTotal',
        'plain: ',
        'bold:now',
        'plain:, see ',
        'link:docs',
        'plain: and ',
        'italic:this',
        'plain:; snake_case_stays',
      ]);
    });
  });

  group('picker state', () {
    test('answers and summary for single + multi + other', () {
      final s = PickerState(const PendingPrompt(kind: PromptKind.question, tool: 't', questions: [q1, q2]));
      expect(s.many, isTrue);
      s.pick(0);
      expect(s.answered(0), isTrue);
      s.step = 1;
      s
        ..pick(2)
        ..pick(0)
        ..pick(1)
        ..pick(1) // toggled off again
        ..setOther(1, 'Peppers');
      expect(s.complete, isTrue);
      expect(s.answers(), [
        {'choice': 0},
        {'choices': [0, 2], 'other': 'Peppers'},
      ]);
      expect(s.summary(), 'Thin · Cheese, Basil, Peppers');
      s.setOther(0, 'Stuffed');
      expect(s.answers().first, {'other': 'Stuffed'});
    });
  });

  group('picker card', () {
    testWidgets('single select: one tap answers', (t) async {
      PickerState? got;
      await t.pumpWidget(wrap(PickerCard(
        prompt: const PendingPrompt(kind: PromptKind.question, tool: 't', questions: [q1]),
        detail: '',
        onAnswer: (s) => got = s,
        onPermission: (_, _) {},
        onQuickReply: (_) {},
        onOther: (_, _) {},
      )));
      expect(find.text('Needs you · Crust'), findsOneWidget);
      expect(find.text('Other…'), findsOneWidget);
      expect(find.text('Yes, go ahead'), findsNothing, reason: 'no generic replies on a real picker');
      await t.tap(find.text('Thick'));
      expect(got!.answers(), [
        {'choice': 1}
      ]);
    });

    testWidgets('two questions step through; multi select submits', (t) async {
      PickerState? got;
      await t.pumpWidget(wrap(PickerCard(
        prompt: const PendingPrompt(kind: PromptKind.question, tool: 't', questions: [q1, q2]),
        detail: '',
        onAnswer: (s) => got = s,
        onPermission: (_, _) {},
        onQuickReply: (_) {},
        onOther: (_, _) {},
      )));
      expect(find.text('1 of 2'), findsOneWidget);
      await t.tap(find.text('Thin'));
      await t.pump();
      expect(find.text('2 of 2'), findsOneWidget);
      expect(got, isNull);
      await t.tap(find.text('Cheese'));
      await t.tap(find.text('Basil'));
      await t.pump();
      await t.tap(find.text('Submit 2 answers'));
      expect(got!.answers(), [
        {'choice': 0},
        {'choices': [0, 2]},
      ]);
    });

    testWidgets('permission prompt: numbered choices', (t) async {
      (int, String)? got;
      await t.pumpWidget(wrap(PickerCard(
        prompt: const PendingPrompt(kind: PromptKind.permission, tool: 'p', title: 'Do you want to proceed?', action: 'approve Bash: npm test', options: [(1, 'Yes'), (2, 'No')]),
        detail: '',
        onAnswer: (_) {},
        onPermission: (n, l) => got = (n, l),
        onQuickReply: (_) {},
        onOther: (_, _) {},
      )));
      expect(find.text('Needs you · Permission'), findsOneWidget);
      expect(find.text('Bash: npm test'), findsOneWidget);
      await t.tap(find.text('No'));
      expect(got, (2, 'No'));
    });

    testWidgets('plain-text question keeps the quick replies', (t) async {
      String? sent;
      await t.pumpWidget(wrap(PickerCard(
        prompt: null,
        detail: 'Two formats exist. Keep RFC 822?',
        onAnswer: (_) {},
        onPermission: (_, _) {},
        onQuickReply: (s) => sent = s,
        onOther: (_, _) {},
      )));
      expect(find.text('Keep RFC 822?'), findsOneWidget);
      await t.tap(find.text('Yes, go ahead'));
      expect(sent, 'Yes, go ahead.');
    });
  });

  testWidgets('tool steps: tap for output; long runs fold', (t) async {
    final tools = [for (var i = 0; i < 7; i++) it('t$i', ChatKind.tool, tool: 'x$i', title: 'Step $i')];
    final res = ChatItem(id: 'r6', kind: ChatKind.result, forTool: 'x6', preview: 'Tests: 41 passed', lines: 9, text: 'Tests: 41 passed');
    await t.pumpWidget(wrap(ToolSteps(tools: tools, resultFor: (c) => c.tool == 'x6' ? res : null)));
    expect(find.text('3 earlier steps'), findsOneWidget);
    expect(find.textContaining('Step 0'), findsNothing);
    await t.tap(find.textContaining('Step 6'));
    await t.pump();
    expect(find.text('Tests: 41 passed'), findsOneWidget);
    expect(find.text('Show all 9 lines'), findsOneWidget);
    await t.tap(find.text('3 earlier steps'));
    await t.pump();
    expect(find.textContaining('Step 0'), findsOneWidget);
  });

  group('chat screen', () {
    late List<http.Request> seen;
    late Map<String, dynamic> snapJson;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      seen = [];
      snapJson = (jsonDecode(File('test/fixtures/state.json').readAsStringSync()) as Map).cast<String, dynamic>();
    });

    Future<void> pumpChat(WidgetTester t, http.Client http) async {
      final client = LoftClient(const Pairing(host: '100.64.0.10:7719', token: 'tok', name: 'fedora'), client: http);
      await t.pumpWidget(ProviderScope(
        overrides: [
          clientProvider.overrideWithValue(client),
          connProvider.overrideWith((ref) => _FakeConn(Conn(snap: Snapshot.fromJson(snapJson), loaded: true, online: true, connecting: false))),
        ],
        child: MaterialApp.router(
          theme: loftTheme(),
          routerConfig: GoRouter(initialLocation: '/chat/a1b2c3d4', routes: [
            GoRoute(path: '/chat/:id', builder: (_, s) => ChatScreen(id: s.pathParameters['id']!, every: const Duration(hours: 1))),
            GoRoute(path: '/ask/:id', builder: (_, _) => const Scaffold(body: Text('ask screen'))),
            GoRoute(path: '/term/:id', builder: (_, _) => const Scaffold(body: Text('terminal screen'))),
          ]),
        ),
      ));
      await t.pump();
      await t.pump();
    }

    testWidgets('renders the session and answers the picker after the Undo window', (t) async {
      await pumpChat(
          t,
          MockClient((r) async {
            seen.add(r);
            if (r.url.path.endsWith('/messages')) return http.Response(messagesJson, 200, headers: {'content-type': 'application/json; charset=utf-8'});
            if (r.url.path.endsWith('/answer')) return http.Response('{"message":"Answered","confirmed":true}', 200);
            return http.Response('{}', 404);
          }));
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('Should I also add a test for the end of the month?'), findsOneWidget);
      expect(find.textContaining('formatted in local time', findRichText: true), findsOneWidget);
      await t.tap(find.text('No, that\'s enough'));
      await t.pump();
      expect(find.textContaining('Answering “No, that\'s enough”'), findsOneWidget);
      expect(seen.where((r) => r.url.path.endsWith('/answer')), isEmpty, reason: 'nothing goes out before the Undo window ends');
      await t.pump(const Duration(seconds: 3));
      await t.pump();
      final ans = seen.firstWhere((r) => r.url.path.endsWith('/answer'));
      expect(jsonDecode(ans.body), {
        'tool': 'toolu_ask1',
        'answers': [
          {'choice': 1}
        ]
      });
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('an older Loft (404) falls back with a note', (t) async {
      await pumpChat(t, MockClient((r) async => http.Response('{"error":"not found"}', 404)));
      await t.pump();
      expect(find.textContaining('Chat needs a newer Loft'), findsOneWidget);
      await t.pumpAndSettle();
      expect(find.text('ask screen'), findsOneWidget, reason: 'the needs card falls back to the It\'s-asking screen');
      await t.pumpWidget(const SizedBox());
    });
  });
}

class _FakeConn extends ConnController {
  _FakeConn(Conn c) : super(null) {
    state = c;
  }
}
