import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loft/data/browser.dart';
import 'package:loft/data/fs.dart';
import 'package:loft/data/loft_client.dart';
import 'package:loft/data/models.dart';
import 'package:loft/screens/folder_picker.dart';
import 'package:loft/state/browser_session.dart';
import 'package:loft/theme/theme.dart';
import 'package:loft/widgets/browser_view.dart';

/// Loft's loft/fs.py listdir() shape.
Map<String, dynamic> dir(String name, String display, {bool git = false, bool web = false}) =>
    {'name': name, 'path': display.replaceFirst('~', '/home/me'), 'display': display, 'git': git, 'web': web};

final home = FsListing.fromJson({
  'path': '/home/me',
  'display': '~',
  'parent': null,
  'dirs': [dir('clients', '~/clients'), dir('loft', '~/loft', git: true, web: true), dir('notes', '~/notes')],
  'recent': [dir('acme-web', '~/clients/acme-web', git: true)],
  'truncated': false,
});

final clients = FsListing.fromJson({
  'path': '/home/me/clients',
  'display': '~/clients',
  'parent': '/home/me',
  'dirs': [dir('acme-web', '~/clients/acme-web', git: true), dir('bloom-shop', '~/clients/bloom-shop')],
  'recent': [],
  'truncated': true,
});

class FakeLink implements BrowserLink {
  final ctl = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  @override
  Stream<dynamic> get stream => ctl.stream;
  @override
  void send(String text) => sent.add((jsonDecode(text) as Map).cast<String, dynamic>());
  @override
  Future<void> close() async => ctl.close();
}

void main() {
  group('fs listing', () {
    test('parses the server shape; recent may be items or strings', () {
      expect(home.atHome, isTrue);
      expect(home.dirs.map((d) => d.name), ['clients', 'loft', 'notes']);
      expect(home.dirs[1].git && home.dirs[1].web, isTrue);
      expect(home.recent.single.display, '~/clients/acme-web');
      final legacy = FsListing.fromJson({'path': '/home/me', 'display': '~', 'recent': ['~/a/b'], 'dirs': []});
      expect(legacy.recent.single.name, 'b');
      expect(clients.parent, '/home/me');
      expect(clients.truncated, isTrue);
      expect(home.filtered('LO').map((d) => d.name), ['loft']);
    });

    test('breadcrumbs carry the path that opens each step', () {
      expect(breadcrumbs('~'), [(label: '~', path: '~')]);
      expect(breadcrumbs('~/clients/acme-web/'), [
        (label: '~', path: '~'),
        (label: 'clients', path: '~/clients'),
        (label: 'acme-web', path: '~/clients/acme-web'),
      ]);
      expect(breadcrumbs('/srv/www').map((c) => c.path), ['/', '/srv', '/srv/www']);
    });
  });

  group('folder picker', () {
    Future<(List<String>, String? Function())> open(WidgetTester t, {FsLoader? load}) async {
      final calls = <String>[];
      String? picked;
      await t.pumpWidget(MaterialApp(
        theme: loftTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => picked = await showFolderPicker(ctx, load: load ??
                  (path, hidden) async {
                    calls.add('$path${hidden ? ' +hidden' : ''}');
                    return switch (path) {
                      '~' || '/home/me' => home,
                      '/home/me/clients' || '~/clients' => clients,
                      _ => FsListing(path: path, display: path.replaceFirst('/home/me', '~'), parent: '/home/me/clients'),
                    };
                  }),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return (calls, () => picked);
    }

    testWidgets('home shows Recent and git badges; a folder opens; Use returns its display path', (t) async {
      final (calls, picked) = await open(t);
      expect(calls, ['~']);
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('~/clients/acme-web'), findsOneWidget); // the recent row's path
      expect(find.text('git'), findsNWidgets(2)); // recent acme-web + loft
      expect(find.text('web'), findsOneWidget);

      await t.tap(find.text('clients'));
      await t.pumpAndSettle();
      expect(calls.last, '/home/me/clients');
      expect(find.text('Recent'), findsNothing, reason: 'Recent only at the top level');
      expect(find.textContaining('only the first ones are listed'), findsOneWidget);

      await t.tap(find.text('Use this folder'));
      await t.pumpAndSettle();
      expect(picked(), '~/clients');
    });

    testWidgets('filter narrows the list; up and the breadcrumb go back', (t) async {
      final (calls, _) = await open(t);
      await t.enterText(find.byType(TextField), 'not');
      await t.pump();
      expect(find.text('notes'), findsOneWidget);
      expect(find.text('loft'), findsNothing);
      expect(find.text('Recent'), findsNothing, reason: 'filtering hides Recent');

      await t.enterText(find.byType(TextField), '');
      await t.pump();
      await t.tap(find.text('clients'));
      await t.pumpAndSettle();
      await t.tap(find.text('acme-web'));
      await t.pumpAndSettle();
      expect(calls.last, '/home/me/clients/acme-web');
      await t.tap(find.byTooltip('Up one folder'));
      await t.pumpAndSettle();
      expect(calls.last, '/home/me/clients');
      await t.tap(find.text('~')); // breadcrumb
      await t.pumpAndSettle();
      expect(calls.last, '~');
    });

    testWidgets('outside home: says so and offers home', (t) async {
      var n = 0;
      await open(t, load: (path, hidden) async {
        if (n++ == 0) return home;
        throw const LoftError('forbidden', status: 403);
      });
      await t.tap(find.text('notes'));
      await t.pumpAndSettle();
      expect(find.textContaining('inside your home folder'), findsOneWidget);
      expect(find.text('Back to home'), findsOneWidget);
    });

    testWidgets('hidden folders toggle asks again with hidden=1', (t) async {
      final (calls, _) = await open(t);
      await t.tap(find.byTooltip('Show hidden folders'));
      await t.pumpAndSettle();
      expect(calls.last, '/home/me +hidden');
    });
  });

  group('browser coordinates', () {
    test('the picture fits, centred sideways and top-aligned', () {
      // 1280x800 frame in a 400x600 box: scale .3125 -> 400x250 at the top.
      expect(fitPicture(const Size(400, 600), const Size(1280, 800)), const Rect.fromLTWH(0, 0, 400, 250));
      // 780x1688 (phone at 2x) in 400x600: scale ~.3555 -> 277.3 wide, centred.
      final r = fitPicture(const Size(400, 600), const Size(780, 1688));
      expect(r.height, closeTo(600, .001));
      expect(r.left, closeTo((400 - r.width) / 2, .001));
      expect(fitPicture(const Size(400, 600), Size.zero), Rect.zero);
    });

    test('taps map to 0..1 of the picture; outside is ignored unless clamped', () {
      const pic = Rect.fromLTWH(50, 0, 300, 200);
      expect(toPageFraction(const Offset(50, 0), pic), Offset.zero);
      expect(toPageFraction(const Offset(200, 100), pic), const Offset(.5, .5));
      expect(toPageFraction(const Offset(350, 200), pic), const Offset(1, 1));
      expect(toPageFraction(const Offset(20, 100), pic), isNull);
      expect(toPageFraction(const Offset(200, 260), pic), isNull);
      expect(toPageFraction(const Offset(400, 260), pic, clamp: true), const Offset(1, 1));
      expect(toPageFraction(const Offset(1, 1), Rect.zero), isNull);
    });

    test('dragging up scrolls down, in page pixels', () {
      const pic = Rect.fromLTWH(0, 0, 400, 250);
      expect(wheelFor(const Offset(0, -40), pic, 1280), const Offset(0, 128));
      expect(wheelFor(const Offset(10, 0), pic, 1280), const Offset(-32, 0));
    });

    test('keyboard diff: append, backspace, autocorrect replace', () {
      expect(keyDiff('', 'hi'), (back: 0, insert: 'hi'));
      expect(keyDiff('hello', 'hell'), (back: 1, insert: ''));
      expect(keyDiff('I teh', 'I the '), (back: 2, insert: 'he '));
      expect(keyDiff('same', 'same'), (back: 0, insert: ''));
    });

    test('messages match the Viewer protocol', () {
      expect(jsonDecode(BrowserMsg.mouse('mousePressed', const Offset(.25, .5))),
          {'type': 'mouse', 'kind': 'mousePressed', 'x': .25, 'y': .5, 'button': 'left', 'clicks': 1});
      expect(jsonDecode(BrowserMsg.mouse('mouseWheel', const Offset(.1, .2), wheel: const Offset(0, 128.4))),
          {'type': 'mouse', 'kind': 'mouseWheel', 'x': .1, 'y': .2, 'dx': 0, 'dy': 128});
      expect(jsonDecode(BrowserMsg.key('Enter')), {'type': 'key', 'key': 'Enter'});
      expect(jsonDecode(BrowserMsg.text('a')), {'type': 'key', 'text': 'a'});
      expect(jsonDecode(BrowserMsg.viewport(true)), {'type': 'viewport', 'mobile': true});
    });
  });

  group('browser viewer', () {
    Future<(BrowserSession, FakeLink)> live(WidgetTester t) async {
      final link = FakeLink();
      final s = BrowserSession(() async => link);
      await s.start();
      final img = await t.runAsync(() async {
        final rec = ui.PictureRecorder();
        Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 1280, 800), Paint()..color = const Color(0xFFFFFFFF));
        return rec.endRecording().toImage(1280, 800);
      });
      s.debugShowFrame(img!);
      await t.binding.setSurfaceSize(const Size(400, 800));
      await t.pumpWidget(MaterialApp(theme: loftTheme(), home: Scaffold(body: SizedBox(width: 400, height: 250, child: BrowserPicture(session: s)))));
      return (s, link);
    }

    testWidgets('a tap clicks the same spot on the page', (t) async {
      final (s, link) = await live(t);
      // The picture fills 400x250; tap at (100, 125) = (.25, .5).
      await t.tapAt(const Offset(100, 125));
      await t.pump(const Duration(milliseconds: 500));
      final kinds = [for (final m in link.sent) m['kind']];
      expect(kinds, ['mouseMoved', 'mousePressed', 'mouseReleased']);
      expect(link.sent[1]['x'], .25);
      expect(link.sent[1]['y'], .5);
      s.dispose();
      await t.binding.setSurfaceSize(null);
    });

    testWidgets('a drag up sends a wheel down', (t) async {
      final (s, link) = await live(t);
      await t.dragFrom(const Offset(200, 200), const Offset(0, -100));
      await t.pump(const Duration(milliseconds: 100));
      final wheels = link.sent.where((m) => m['kind'] == 'mouseWheel').toList();
      expect(wheels, isNotEmpty);
      final dy = wheels.fold<num>(0, (a, m) => a + (m['dy'] as num));
      expect(dy, greaterThan(0));
      // 100 px of a 400 px wide picture of a 1280 px page = ~320 page px (minus the drag slop).
      expect(dy, inInclusiveRange(250, 330));
      s.dispose();
      await t.binding.setSurfaceSize(null);
    });

    test('events: url, errors, toasts, hello', () async {
      final link = FakeLink();
      final s = BrowserSession(() async => link, openMsg: BrowserMsg.site('3f9c01ab'));
      final toasts = <String>[];
      s.toasts.listen((x) => toasts.add(x.text));
      await s.start();
      expect(link.sent.first, {'type': 'site', 'id': '3f9c01ab'});
      link.ctl.add(jsonEncode({'type': 'hello', 'mcp': true, 'ports': [5173]}));
      link.ctl.add(jsonEncode({'type': 'url', 'url': 'http://localhost:5173/'}));
      link.ctl.add(jsonEncode({'type': 'err', 'text': '404 /favicon.ico'}));
      link.ctl.add(jsonEncode({'type': 'toast', 'text': 'Saved'}));
      await Future<void>.delayed(Duration.zero);
      expect(s.agentDriven, isTrue);
      expect(s.ports, [5173]);
      expect(shortUrl(s.url), 'localhost:5173');
      expect(s.errors, ['404 /favicon.ico']);
      expect(toasts, ['Saved']);
      s.typeDiff('', 'ab\nc');
      expect(link.sent.skip(1).toList(), [
        {'type': 'key', 'text': 'ab'},
        {'type': 'key', 'key': 'Enter'},
        {'type': 'key', 'text': 'c'},
      ]);
      s.dispose();
    });

    test('an older Loft refusing the socket is "refused", not an error loop', () async {
      final s = BrowserSession(() async => throw const LoftError('not found', status: 404));
      await s.start();
      expect(s.status, BrowserStatus.refused);
      expect(s.message, contains('Update Loft'));
      s.dispose();
    });
  });

  group('sites and badges', () {
    test('GET /api/sites: the documented shape', () {
      final i = SitesInfo.fromJson({
        'chrome': true,
        'accounts': [
          {
            'account': 'work',
            'label': 'Work',
            'hex': '#5B8DFF',
            'sites': [
              {'id': '3f9c01ab', 'name': 'Helpdesk', 'url': 'https://help.example.com', 'cookies': 7, 'signedIn': true},
              {'id': '77', 'name': '', 'url': 'https://sheets.example.com/x', 'signedIn': false},
            ],
            'browser': {'running': true, 'window': false},
            'profile': true,
          },
          {'account': 'me', 'label': 'Me', 'sites': [], 'browser': {'running': false, 'window': true}},
        ],
        'agents': [
          {'id': '1a2b3c4d', 'name': 'Fix the import', 'account': 'work', 'col': 'running', 'url': 'https://help.example.com/t', 'live': true, 'sitesAccount': 'work'}
        ],
      });
      expect(i.accounts.map((a) => a.id), ['work', 'me']);
      expect(i.accounts.first.color, 0xFF5B8DFF);
      expect(i.accounts.first.running, isTrue);
      expect(i.account('me')!.window, isTrue);
      expect(i.sites.map((s) => '${s.account}:${s.id}'), ['work:3f9c01ab', 'work:77']);
      expect(i.sites[1].name, 'sheets.example.com', reason: 'name defaults to the host');
      expect(i.sites[1].signedIn, isFalse);
      expect(i.agents.single.live, isTrue);
      expect(i.agents.single.sitesAccount, 'work');
      // Other shapes still parse.
      expect(SitesInfo.fromJson({'accounts': {'studio': [{'id': 's1', 'url': 'a.example.com'}]}}).sites.single.host, 'a.example.com');
      expect(SitesInfo.fromJson([{'id': 'x', 'url': 'https://b.example.com'}]).sites.single.id, 'x');
    });

    test('sites socket: hello carries the account entry; window ends the stream', () async {
      final link = FakeLink();
      final s = BrowserSession(() async => link);
      await s.start();
      link.ctl.add(jsonEncode({'type': 'hello', 'account': 'work', 'label': 'Work', 'sites': [{'id': 'a', 'name': 'A', 'url': 'https://a.example.com'}], 'browser': {'running': true}}));
      await Future<void>.delayed(Duration.zero);
      expect(s.sitesAccount!.sites.single.name, 'A');
      link.ctl.add(jsonEncode({'type': 'window'}));
      await link.ctl.close();
      await Future<void>.delayed(Duration.zero);
      expect(s.inWindow, isTrue);
      expect(s.status, BrowserStatus.closed);
      expect(s.message, contains('window on the laptop'));
      s.dispose();
    });

    test('card browser badge', () {
      final c = AgentCard.fromJson({
        'id': 'a1',
        'kind': 'agent',
        'name': 'x',
        'col': 'running',
        'browser': {
          'mcp': true,
          'running': false,
          'url': 'https://help.example.com/tickets',
          'live': true,
          'account': 'work',
          'checks': {'ok': false, 'passed': 2, 'total': 3}
        }
      });
      expect(c.hasBrowser, isTrue);
      expect(c.browser!.summary, 'checks 2/3');
      expect(c.browser!.live, isTrue);
      expect(c.browser!.sitesAccount, 'work');
      expect(AgentCard.fromJson({'id': 'a2', 'col': 'done', 'browser': null}).hasBrowser, isFalse);
    });
  });
}
