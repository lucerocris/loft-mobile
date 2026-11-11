import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loft/data/models.dart';
import 'package:loft/data/pairing.dart';
import 'package:loft/data/sse.dart';
import 'package:loft/voice/trailing_command.dart';

Map<String, dynamic> fixture() => (jsonDecode(File('test/fixtures/state.json').readAsStringSync()) as Map).cast<String, dynamic>();

void main() {
  group('trailing command (same cases as desktop deliver())', () {
    final cases = <String, (String, bool)>{
      'Check the appeal cards, send it.': ('Check the appeal cards', true),
      'Check the appeal cards. Start it!': ('Check the appeal cards', true),
      'fix the build start it': ('fix the build', true),
      'Yes, go ahead and send it.': ('Yes', true),
      'go ahead and send': ('', true),
      'Do not send it to Peter': ('Do not send it to Peter', false),
      'start it later please': ('start it later please', false),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final t = parseTrailing(e.key);
        expect((t.text, t.go), e.value);
      });
    }
  });

  group('partial split', () {
    test('words already heard stay, new words are provisional', () {
      final s = splitPartial('go ahead with zero and', 'go ahead with zero and one, skip the PR for now');
      expect(s.stable, 'go ahead with zero and');
      expect(s.tail, 'one, skip the PR for now');
    });
    test('a rewrite of earlier words moves them back into the tail', () {
      final s = splitPartial('check the appeal cars', 'check the appeal cards today');
      expect(s.stable, 'check the appeal');
      expect(s.tail, 'cards today');
    });
  });

  group('SSE parser', () {
    test('events across arbitrary chunk boundaries, comments as heartbeats', () {
      final got = <SseEvent>[];
      var pings = 0;
      final p = SseParser(onEvent: got.add, onComment: (_) => pings++);
      const stream = 'data: {"a":1}\n\n: ping\n\ndata: line1\ndata: line2\r\n\r\nevent: x\ndata: y\n\n';
      for (var i = 0; i < stream.length; i += 3) {
        p.add(stream.substring(i, (i + 3).clamp(0, stream.length)));
      }
      expect(got.map((e) => e.data), ['{"a":1}', 'line1\nline2', 'y']);
      expect(got.last.event, 'x');
      expect(pings, 1);
    });

    test('sseEvents over bytes, split inside a UTF-8 character', () async {
      final bytes = utf8.encode('data: {"name":"Violations · SOP"}\n\n: ping\n\n');
      final cut = bytes.indexOf(0xC2) + 1; // middle of "·"
      final events = await sseEvents(Stream.fromIterable([bytes.sublist(0, cut), bytes.sublist(cut)])).toList();
      expect(events.length, 2);
      expect(jsonDecode(events.first!.data)['name'], 'Violations · SOP');
      expect(events.last, isNull);
    });
  });

  group('snapshot model', () {
    final s = Snapshot.fromJson(fixture());
    test('parses cards, usage, dirs', () {
      expect(s.cards.length, 5);
      expect(s.voice, isTrue);
      expect(s.dirs.first, '~/evotech-intern/e8-ops-automation');
      expect(s.work.five, '—');
      expect(s.work.fill, closeTo(.18, 1e-9));
      expect(s.personal.hot, isTrue); // 88% >= 85%
      expect(s.work.hot, isFalse);
    });
    test('sections and filters', () {
      expect(s.section(Col.needs, '').map((c) => c.id), ['a1b2c3d4']);
      expect(s.section(Col.needs, 'personal'), isEmpty);
      expect(s.section(Col.done, 'personal').length, 2);
      expect(s.byId('t1234abcd')!.line, 'Not started');
      expect(s.byId('c9d0e1f2')!.line, 'Long-press lookup works on the emulator');
      expect(s.byId('0badf00d')!.failed, isTrue);
      expect(s.byId('0badf00d')!.projectLabel, 'home');
      expect(s.needsIds, {'a1b2c3d4'});
    });
    test('ask split', () {
      final a = splitAsk(s.byId('a1b2c3d4')!.detail);
      expect(a.question, 'Start steps 0 and 1?');
      expect(a.body, startsWith('I found why'));
      expect(splitAsk('Just a status line.').question, '');
      expect(splitAsk('Ready?').question, 'Ready?');
    });
    test('ages', () {
      final now = DateTime.utc(2026, 11, 11, 12, 7);
      expect(ago(DateTime.utc(2026, 11, 11, 11, 20), now: now), '47m');
      expect(ago(DateTime.utc(2026, 11, 11, 12, 6, 30), now: now), 'now');
      expect(ago(DateTime.utc(2026, 11, 10, 9), now: now), '1d');
      expect(ago(null), '');
    });
    test('derived title matches server.py derive_title', () {
      expect(deriveTitle('Please check why the appeal cards stopped matching after Monday and draft a fix.'), 'Check why the appeal cards stopped matching…');
      expect(deriveTitle('fix the build. Then push.'), 'Fix the build');
      expect(deriveTitle('   '), '');
    });
  });

  group('pairing', () {
    test('desktop QR uri', () {
      final p = Pairing.fromUri('loft://pair?h=100.119.140.39:7717&t=abc-DEF_123&n=fedora')!;
      expect(p.host, '100.119.140.39:7717');
      expect(p.token, 'abc-DEF_123');
      expect(p.name, 'fedora');
      expect(p.auth, {'Authorization': 'Bearer abc-DEF_123'});
      expect(p.ws('/ws/voice').toString(), 'ws://100.119.140.39:7717/ws/voice');
    });
    test('rejects other links', () {
      expect(Pairing.fromUri('https://example.com/?h=1&t=2'), isNull);
      expect(Pairing.fromUri('loft://pair?h=100.1.1.1:7717'), isNull);
    });
    test('address normalisation', () {
      expect(Pairing.normalizeHost('100.119.140.39'), '100.119.140.39:7717');
      expect(Pairing.normalizeHost('http://100.119.140.39:7719/'), '100.119.140.39:7719');
      expect(Pairing.normalizeHost('fedora:99999'), isNull);
      expect(Pairing.normalizeHost(''), isNull);
    });
  });
}
