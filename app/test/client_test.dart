import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loft/data/loft_client.dart';
import 'package:loft/data/outbox.dart';
import 'package:loft/data/pairing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const pairing = Pairing(host: '100.119.140.39:7719', token: 'tok123', name: 'fedora');
final fixture = File('test/fixtures/state.json').readAsStringSync();

void main() {
  test('sends the bearer token and parses state', () async {
    late http.Request seen;
    final c = LoftClient(pairing, client: MockClient((r) async {
      seen = r;
      return http.Response(fixture, 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final s = await c.state();
    expect(seen.url.toString(), 'http://100.119.140.39:7719/api/state');
    expect(seen.headers['Authorization'], 'Bearer tok123');
    expect(s.cards.length, 5);
  });

  test('create posts the same body as desktop Loft', () async {
    late Map body;
    final c = LoftClient(pairing, client: MockClient((r) async {
      expect(r.url.path, '/api/cards');
      body = jsonDecode(r.body) as Map;
      return http.Response('{"message":"started 1a2b3c4d in e8"}', 200);
    }));
    final m = await c.create(prompt: 'Fix it', account: 'work', cwd: '~/e8', start: true);
    expect(m, 'started 1a2b3c4d in e8');
    expect(body, {'prompt': 'Fix it', 'title': '', 'account': 'work', 'cwd': '~/e8', 'start': true});
  });

  test('card actions hit /api/cards/<id>/<action>', () async {
    final paths = <String>[];
    final c = LoftClient(pairing, client: MockClient((r) async {
      paths.add('${r.method} ${r.url.path} ${r.body}');
      return http.Response('{"message":"ok"}', 200);
    }));
    await c.reply('a1', 'Yes, go ahead.');
    await c.act('a1', 'stop');
    await c.act('a1', 'archive');
    expect(paths, ['POST /api/cards/a1/reply {"text":"Yes, go ahead."}', 'POST /api/cards/a1/stop {}', 'POST /api/cards/a1/archive {}']);
  });

  test('401 means unpaired; network errors are offline', () async {
    final c401 = LoftClient(pairing, client: MockClient((r) async => http.Response('{"error":"not paired"}', 401)));
    await expectLater(c401.ping(), throwsA(isA<LoftError>().having((e) => e.unauthorized, 'unauthorized', true).having((e) => e.offline, 'offline', false)));
    final cDown = LoftClient(pairing, client: MockClient((r) async => throw const SocketException('No route to host')));
    await expectLater(cDown.ping(), throwsA(isA<LoftError>().having((e) => e.offline, 'offline', true)));
    final c400 = LoftClient(pairing, client: MockClient((r) async => http.Response('{"message":"Pick a project folder that exists."}', 400)));
    await expectLater(c400.create(prompt: 'x', account: 'work', cwd: '~/nope', start: false), throwsA(isA<LoftError>().having((e) => e.message, 'message', 'Pick a project folder that exists.')));
  });

  test('events() streams snapshots and heartbeats', () async {
    final c = LoftClient(pairing, client: MockClient.streaming((r, _) async {
      expect(r.headers['Authorization'], 'Bearer tok123');
      final body = Stream<List<int>>.fromIterable([utf8.encode('data: ${jsonEncode(jsonDecode(fixture))}\n\n'), utf8.encode(': ping\n\n')]);
      return http.StreamedResponse(body, 200);
    }));
    final got = await c.events().toList();
    expect(got.length, 2);
    expect(got.first!.cards.length, 5);
    expect(got.last, isNull);
  });

  group('outbox', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('keeps items while offline, sends in order when back, drops rejected ones', () async {
      final ob = await Outbox.load();
      await ob.add(OutboxItem('reply', {'id': 'a1', 'text': 'one'}));
      await ob.add(OutboxItem('reply', {'id': 'gone', 'text': 'two'}));
      await ob.add(OutboxItem('create', {'prompt': 'three', 'account': 'personal', 'cwd': '~/x', 'start': false}));

      final down = LoftClient(pairing, client: MockClient((r) async => throw const SocketException('down')));
      var r = await ob.flush(down);
      expect((r.sent, ob.items.length), (0, 3));
      expect((await Outbox.load()).items.length, 3); // persisted

      final sent = <String>[];
      final up = LoftClient(pairing, client: MockClient((r) async {
        sent.add(r.url.path);
        if (r.url.path.contains('gone')) return http.Response('{"message":"That card is gone"}', 404);
        return http.Response('{"message":"ok"}', 200);
      }));
      r = await ob.flush(up);
      expect(sent, ['/api/cards/a1/reply', '/api/cards/gone/reply', '/api/cards']);
      expect(r.sent, 2);
      expect(r.errors.single, contains('That card is gone'));
      expect(ob.items, isEmpty);
      expect((await Outbox.load()).items, isEmpty);
    });
  });
}
