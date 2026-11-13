import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loft/data/grouping.dart';
import 'package:loft/data/loft_client.dart';
import 'package:loft/data/models.dart';
import 'package:loft/data/pairing.dart';
import 'package:loft/screens/assistant_screen.dart';
import 'package:loft/screens/inbox_screen.dart';
import 'package:loft/state/assistant.dart';
import 'package:loft/state/conn.dart';
import 'package:loft/theme/theme.dart';
import 'package:loft/widgets/agent_menu.dart';
import 'package:loft/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pairing = Pairing(host: '100.64.0.10:7719', token: 'tok', name: 'fedora');
const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _state() => (jsonDecode(File('test/fixtures/state.json').readAsStringSync()) as Map).cast<String, dynamic>();

/// state.json plus summaries and the assistant's own card.
Map<String, dynamic> stateWithAssistant() {
  final j = _state();
  final cards = [for (final c in j['cards'] as List) Map<String, dynamic>.from(c as Map)];
  cards.first['summary'] = 'Find why the export totals don\'t match.';
  cards.add({
    'kind': 'agent', 'id': 'as000001', 'name': 'Loft Assistant', 'summary': 'Operates Loft for you.', 'assistant': true,
    'col': 'done', 'state': 'idle', 'detail': '', 'result': '', 'cwd': '~/.loft/assistant', 'updated': '2026-11-11T12:00:00+00:00',
  });
  return {...j, 'cards': cards};
}

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200, headers: _json);

Map<String, dynamic> _page(String id, List<Map<String, dynamic>> items, {String state = 'done'}) => {
      'id': id, 'state': state, 'working': state == 'running', 'detail': '', 'session': 's-$id', 'size': items.length,
      'cursor': items.length, 'start': 0, 'more': false, 'gap': false, 'pending': null, 'items': items,
    };

void main() {
  group('summary and the assistant card in the snapshot', () {
    test('summary parses; empty is null', () {
      final s = Snapshot.fromJson(stateWithAssistant());
      expect(s.byId('a1b2c3d4')!.summary, 'Find why the export totals don\'t match.');
      expect(s.byId('e5f6a7b8')!.summary, isNull);
      expect(AgentCard.fromJson({'id': 'x', 'summary': '  '}).summary, isNull);
    });

    test('the assistant card is never in the inbox, but can be looked up', () {
      final s = Snapshot.fromJson(stateWithAssistant());
      expect(s.cards.where((c) => c.id == 'as000001'), isEmpty);
      expect(s.assistant!.id, 'as000001');
      expect(s.byId('as000001')!.assistant, isTrue);
      for (final g in GroupBy.values) {
        expect(buildGroups(s, g).expand((x) => x.cards).where((c) => c.assistant), isEmpty, reason: '$g');
      }
      expect(s.section(Col.done, '').where((c) => c.assistant), isEmpty);
    });
  });

  group('client', () {
    test('rename, describe, bulk and assistant bodies', () async {
      final seen = <http.Request>[];
      final c = LoftClient(_pairing, client: MockClient((r) async {
        seen.add(r);
        return switch (r.url.path) {
          '/api/cards/a1/describe' => _ok({'title': 'Fix export totals', 'summary': 'Find the missing rows.'}),
          '/api/bulk' => _ok({'message': 'Archived 2 agents', 'count': 2, 'ids': ['a', 'b']}),
          '/api/assistant' when r.method == 'GET' => _ok({'id': null, 'card': null, 'account': 'personal', 'running': false}),
          '/api/assistant' => _ok({'id': 'as1', 'message': 'Sent'}),
          _ => _ok({'message': 'renamed'}),
        };
      }));
      expect(await c.rename('a1', summary: 'Just the summary'), 'renamed');
      expect(jsonDecode(seen.last.body), {'summary': 'Just the summary'});
      await c.rename('a1', title: 'New title');
      expect(jsonDecode(seen.last.body), {'title': 'New title', 'name': 'New title'}, reason: 'name keeps older Loft working');
      final d = await c.describe('a1');
      expect((d.title, d.summary), ('Fix export totals', 'Find the missing rows.'));
      final b = await c.bulk('archive', filter: 'done');
      expect(jsonDecode(seen.last.body), {'action': 'archive', 'filter': 'done'});
      expect(b.count, 2);
      expect(b.ids, ['a', 'b']);
      await c.bulk('archive', ids: ['x']);
      expect(jsonDecode(seen.last.body)['ids'], ['x']);
      final info = await c.assistant();
      expect(info!.id, isNull);
      expect(await c.askAssistant('What needs me?'), 'as1');
      expect(jsonDecode(seen.last.body), {'message': 'What needs me?'});
    });

    test('an older Loft: GET /api/assistant 404 means no assistant', () async {
      final c = LoftClient(_pairing, client: MockClient((r) async => http.Response('{"error":"not found"}', 404)));
      expect(await c.assistant(), isNull);
    });
  });

  testWidgets('inbox row shows the summary under the title', (t) async {
    final s = Snapshot.fromJson(stateWithAssistant());
    await t.pumpWidget(MaterialApp(theme: loftTheme(), home: Scaffold(body: AgentItem(card: s.byId('a1b2c3d4')!, onTap: () {}))));
    expect(find.text('Invoices · export diff'), findsOneWidget);
    expect(find.text('Find why the export totals don\'t match.'), findsOneWidget);
    expect(find.textContaining('Start steps 0 and 1?'), findsOneWidget);
  });

  testWidgets('rename dialog returns only what changed', (t) async {
    const c = AgentCard(id: 'a1', kind: 'agent', name: 'Old', col: Col.running, summary: 'Old summary');
    ({String? title, String? summary})? got;
    var closed = false;
    await t.pumpWidget(MaterialApp(
      theme: loftTheme(),
      home: Builder(builder: (ctx) => TextButton(onPressed: () async {
        got = await showRenameDialog(ctx, c);
        closed = true;
      }, child: const Text('go'))),
    ));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('rename-summary')), 'Make the export match the ledger.');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(closed, isTrue);
    expect(got!.title, isNull);
    expect(got!.summary, 'Make the export match the ledger.');
  });

  group('screens', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<List<http.Request>> pump(WidgetTester t, String at, Future<http.Response> Function(http.Request r) handler, {Map<String, dynamic>? snap}) async {
      final seen = <http.Request>[];
      final client = LoftClient(_pairing, client: MockClient((r) async {
        seen.add(r);
        return handler(r);
      }));
      await t.pumpWidget(ProviderScope(
        overrides: [
          clientProvider.overrideWithValue(client),
          connProvider.overrideWith((ref) => _FakeConn(Conn(snap: Snapshot.fromJson(snap ?? stateWithAssistant()), loaded: true, online: true, connecting: false))),
        ],
        child: MaterialApp.router(
          theme: loftTheme(),
          routerConfig: GoRouter(initialLocation: at, routes: [
            GoRoute(path: '/', builder: (_, _) => const InboxScreen()),
            GoRoute(path: '/assistant', builder: (_, _) => const AssistantScreen(every: Duration(hours: 1))),
          ]),
        ),
      ));
      await t.pump();
      await t.pump();
      return seen;
    }

    testWidgets('inbox: assistant entry, no assistant row, and Archive all done with confirm', (t) async {
      final seen = await pump(t, '/', (r) async {
        if (r.url.path == '/api/assistant') return _ok({'id': 'as000001', 'card': null, 'account': 'personal', 'running': false});
        if (r.url.path == '/api/bulk') return _ok({'message': 'Archived 2 agents', 'count': 2, 'ids': ['c9d0e1f2', '0badf00d']});
        return http.Response('{}', 404);
      });
      expect(find.byTooltip('Loft Assistant'), findsOneWidget, reason: 'the snapshot has an assistant card');
      await t.tap(find.text('Show'));
      await t.pump();
      expect(find.text('Loft Assistant'), findsNothing, reason: 'the assistant\'s own card is not an inbox row');
      await t.tap(find.text('Archive all'));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Archive 2 done agents?'), findsOneWidget);
      await t.tap(find.widgetWithText(Btn, 'Archive all'));
      await t.pump(const Duration(milliseconds: 500));
      final bulk = seen.singleWhere((r) => r.url.path == '/api/bulk');
      expect(jsonDecode(bulk.body), {'action': 'archive', 'filter': 'done'});
      expect(find.text('Archived 2 agents'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('inbox: an older Loft (404) hides the assistant entry', (t) async {
      await pump(t, '/', (r) async => http.Response('{"error":"not found"}', 404), snap: _state());
      await t.pump();
      expect(find.byTooltip('Loft Assistant'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('assistant: a suggestion sends, the reply shows; New conversation resets', (t) async {
      final noAssistant = _state();
      var started = false;
      final seen = await pump(t, '/assistant', (r) async {
        final p = r.url.path;
        if (p == '/api/assistant' && r.method == 'GET') return _ok({'id': started ? 'as9' : null, 'card': null, 'account': 'personal', 'running': false});
        if (p == '/api/assistant') {
          started = true;
          return _ok({'id': 'as9', 'message': 'Sent'});
        }
        if (p == '/api/assistant/reset') return _ok({'message': 'New conversation'});
        if (p == '/api/cards/as9/messages') {
          return _ok(_page('as9', [
            {'id': 'm1', 'kind': 'user', 'text': 'What needs me?'},
            {'id': 'm2', 'kind': 'tool', 'tool': 'tu1', 'name': 'mcp__loft__list_cards', 'title': 'Cards that need you', 'detail': ''},
            {'id': 'm3', 'kind': 'result', 'for': 'tu1', 'ok': true, 'preview': 'a1b2c3d4', 'lines': 1, 'text': 'a1b2c3d4'},
            {'id': 'm4', 'kind': 'assistant', 'text': 'One needs you: Invoices · export diff.'},
          ]));
        }
        return http.Response('{}', 404);
      }, snap: noAssistant);
      expect(find.text('What should Loft do?'), findsOneWidget);
      for (final s in assistantSuggestions) {
        expect(find.text(s.label), findsOneWidget);
      }
      await t.tap(find.text('What needs me?'));
      await t.pump();
      await t.pump();
      await t.pump();
      final ask = seen.firstWhere((r) => r.url.path == '/api/assistant' && r.method == 'POST');
      expect(jsonDecode(ask.body), {'message': 'What needs me?'});
      expect(find.text('One needs you: Invoices · export diff.', findRichText: true), findsOneWidget);
      expect(find.text('Ran 1 Loft command'), findsOneWidget, reason: 'tool steps fold into one quiet row');
      expect(find.textContaining('Cards that need you'), findsNothing);
      await t.tap(find.text('Ran 1 Loft command'));
      await t.pump();
      expect(find.textContaining('Cards that need you'), findsOneWidget);
      await t.tap(find.byTooltip('New conversation'));
      await t.pump();
      await t.pump();
      expect(seen.where((r) => r.url.path == '/api/assistant/reset'), hasLength(1));
      expect(find.text('What should Loft do?'), findsOneWidget, reason: 'back to the empty conversation');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('assistant: an older Loft says so', (t) async {
      await pump(t, '/assistant', (r) async => http.Response('{"error":"not found"}', 404), snap: _state());
      await t.pump();
      expect(find.text('Needs a newer Loft'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  test('assistant support: seen() marks it available', () {
    final n = AssistantSupport(null);
    expect(n.state, isNull);
    n.seen();
    expect(n.state, isTrue);
  });
}

class _FakeConn extends ConnController {
  _FakeConn(Conn c) : super(null) {
    state = c;
  }
}
