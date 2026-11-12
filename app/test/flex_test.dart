import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loft/data/grouping.dart';
import 'package:loft/data/loft_client.dart';
import 'package:loft/data/models.dart';
import 'package:loft/data/pairing.dart';
import 'package:loft/theme/theme.dart';
import 'package:loft/widgets/common.dart';

Snapshot load(String name) => Snapshot.fromJson((jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map).cast<String, dynamic>());

void main() {
  final free = load('state_freelancer'); // 2 accounts, 4 projects, Northwind on both
  final solo = load('state_solo'); // 1 account, no projects
  final legacy = load('state'); // an older Loft: no accounts/projects/groupBy

  group('snapshot: accounts and projects', () {
    test('accounts, colors and usage come from the server', () {
      expect(free.accounts.map((a) => a.label), ['Studio', 'Overflow']);
      expect(free.account('overflow')!.color, 0xFFA98BFF);
      expect(free.usageOf('overflow').fivePct, 64);
      expect(free.multiAccount, isTrue);
      expect(free.supportsProjects, isTrue);
      expect(free.groupBy, 'project');
    });
    test('card.project is a project id; null is Unsorted', () {
      expect(free.projectOf(free.byId('a0000003')!)!.name, 'Northwind · app');
      expect(free.byId('a0000008')!.projectId, isNull);
      expect(free.project('northwind')!.accounts, ['studio', 'overflow']);
      expect(free.project('northwind')!.defaultAccount, 'auto');
    });
    test('an unknown project id shows as Unsorted', () {
      final j = (jsonDecode(File('test/fixtures/state_freelancer.json').readAsStringSync()) as Map).cast<String, dynamic>();
      (j['cards'] as List).first['project'] = 'deleted-one';
      final s = Snapshot.fromJson(j);
      expect(projectKey(s, s.cards.first), unsortedKey);
    });
    test('colors: hex, palette name, or by position', () {
      expect(parseColor('#112233', null, 0), 0xFF112233);
      expect(parseColor(null, 'pink', 0), 0xFFF17DB8);
      expect(parseColor(null, 'nonsense', 1), 0xFF46C07D);
    });
  });

  test('projectDirs: own folders, its agents\' repos (worktrees folded), subfolders of recents', () {
    final j = (jsonDecode(File('test/fixtures/state_freelancer.json').readAsStringSync()) as Map).cast<String, dynamic>();
    final p = (j['projects'] as List).first as Map;
    p['folders'] = ['~/work/acme'];
    final cards = j['cards'] as List;
    for (final c in cards) {
      (c as Map)['project'] = null;
    }
    (cards[0] as Map)..['project'] = p['id']..['folder'] = '~/work/acme-api/.claude/worktrees/fix-x';
    (cards[1] as Map)..['project'] = p['id']..['folder'] = '~/work/acme';
    j['dirs'] = ['~/work/acme/web', '~/work/other'];
    final s = Snapshot.fromJson(j);
    expect(projectDirs(s, s.project('${p['id']}')!), ['~/work/acme', '~/work/acme-api', '~/work/acme/web']);
  });

  group('old server fallback', () {
    test('no projects field: project UI off, folder name is not a project', () {
      expect(legacy.supportsProjects, isFalse);
      expect(legacy.projects, isNull);
      expect(legacy.byId('a1b2c3d4')!.projectId, isNull);
      expect(legacy.byId('a1b2c3d4')!.folderName, 'acme-app');
    });
    test('accounts come from the usage keys and the work flag', () {
      expect(legacy.accounts.map((a) => a.id), ['work', 'personal']);
      expect(legacy.byId('a1b2c3d4')!.account, 'work');
      expect(legacy.byId('c9d0e1f2')!.account, 'personal');
    });
    test('Group by offers no Project and falls back to Status', () {
      expect(groupChoices(legacy), isNot(contains(GroupBy.project)));
      expect(effectiveGroupBy('project', legacy), GroupBy.status);
    });
  });

  test('optional pendingAccount on a card (queued account switch)', () {
    final j = (jsonDecode(File('test/fixtures/state_freelancer.json').readAsStringSync()) as Map).cast<String, dynamic>();
    (j['cards'] as List).first['pendingAccount'] = 'overflow';
    final s = Snapshot.fromJson(j);
    expect(s.cards.first.pendingAccount, 'overflow');
    expect(free.cards.first.pendingAccount, isNull);
  });

  group('grouping', () {
    test('by project: one section per project, Unsorted last, then Done', () {
      final g = buildGroups(free, GroupBy.project);
      expect(g.map((x) => x.label), ['Acme · website', 'Northwind · app', 'Bloom · shop', 'Harbor · API', 'Unsorted', 'Done']);
      final nw = g[1];
      expect(nw.cards.map((c) => c.col), [Col.running, Col.running, Col.todo]);
      expect(nw.accounts, ['studio', 'overflow']);
      expect(g[0].needs, 1);
      expect(g.last.cards.single.id, 'a0000009');
    });
    test('by account and by status', () {
      expect(buildGroups(free, GroupBy.account).map((x) => x.label), ['Studio', 'Overflow', 'Done']);
      final s = buildGroups(free, GroupBy.status);
      expect(s.first.label, 'Needs you');
      expect(s.first.alert, isTrue);
      expect(s.first.cards.map((c) => c.id).toSet(), {'a0000001', 'a0000006'});
    });
    test('by folder and none', () {
      final f = buildGroups(free, GroupBy.folder);
      expect(f.map((x) => x.label), containsAll(['acme-web', 'northwind-app', 'dotfiles']));
      final n = buildGroups(free, GroupBy.none);
      expect(n.first.label, '');
      expect(n.first.cards.first.col, Col.needs); // needs you still on top
    });
    test('filter chips follow the active dimension', () {
      final p = filterOptions(free, filterDim(GroupBy.project, free));
      expect(p.first.label, 'All');
      expect(p.first.count, 8); // done cards don't count
      expect(p.map((o) => o.key), containsAll(['acme', 'northwind', unsortedKey]));
      expect(p.firstWhere((o) => o.key == 'northwind').count, 3);
      final only = buildGroups(free, GroupBy.project, filter: 'bloom');
      expect(only.where((x) => !x.isDone).single.cards.single.id, 'a0000006');
    });
    test('one account: no Account grouping, no account filter', () {
      expect(groupChoices(solo), [GroupBy.status, GroupBy.project, GroupBy.folder, GroupBy.none]);
      expect(filterDim(GroupBy.status, solo), FilterDim.none);
      expect(filterOptions(solo, FilterDim.none), isEmpty);
      expect(effectiveGroupBy('account', solo), GroupBy.status);
    });
    test('phone choice wins over the server default', () {
      expect(effectiveGroupBy(null, free), GroupBy.project);
      expect(effectiveGroupBy('folder', free), GroupBy.folder);
    });
  });

  group('new task: account for a project', () {
    test('Auto picks the allowed account with the most 5h left', () {
      expect(free.resolveAccount(autoAccount, project: free.project('northwind'))!.id, 'studio'); // 31% < 64%
      expect(free.resolveAccount(autoAccount, project: free.project('bloom'))!.id, 'overflow'); // only allowed one
    });
    test('choices are limited to the project and start at its default', () {
      expect(accountChoices(free, free.project('bloom')).map((a) => a.id), ['overflow']);
      expect(accountChoices(free, null).length, 2);
      expect(initialAccountChoice(free, free.project('northwind')), autoAccount);
      expect(initialAccountChoice(free, free.project('acme')), 'studio');
      expect(initialAccountChoice(free, null), 'studio'); // Loft's default
    });
  });

  group('client: project routes', () {
    const pairing = Pairing(host: '10.0.2.2:7731', token: 't', name: 'fake');
    test('create sends project and "auto"; card move; project CRUD', () async {
      final seen = <String>[];
      final c = LoftClient(pairing, client: MockClient((r) async {
        seen.add('${r.method} ${r.url.path} ${r.body}');
        if (r.url.path == '/api/projects' && r.method == 'POST') return http.Response('{"id":"p1","name":"X","color":"pink","accounts":[],"defaultAccount":"auto","folders":[]}', 200);
        return http.Response('{"message":"ok"}', 200);
      }));
      await c.create(prompt: 'Fix', account: autoAccount, cwd: '~/a', start: true, project: 'northwind');
      await c.create(prompt: 'Fix', account: 'studio', cwd: '~/a', start: false);
      await c.setCardProject('a1', 'p1');
      await c.setCardProject('a1', null);
      final p = await c.createProject(const Project(id: '', name: 'X', color: 0xFFF17DB8, colorName: 'pink'));
      await c.updateProject('p1', {'name': 'Y'});
      await c.deleteProject('p1');
      expect(p.id, 'p1');
      expect(seen, [
        'POST /api/cards {"prompt":"Fix","title":"","account":"auto","cwd":"~/a","start":true,"project":"northwind"}',
        'POST /api/cards {"prompt":"Fix","title":"","account":"studio","cwd":"~/a","start":false}',
        'POST /api/cards/a1/project {"project":"p1"}',
        'POST /api/cards/a1/project {"project":null}',
        'POST /api/projects {"name":"X","color":"pink","accounts":[],"defaultAccount":"auto","folders":[]}',
        'PATCH /api/projects/p1 {"name":"Y"}',
        'DELETE /api/projects/p1 {}',
      ]);
    });
  });

  group('widgets', () {
    Widget wrap(Widget w) => MaterialApp(theme: loftTheme(), home: Scaffold(body: w));
    testWidgets('agent item: project tag, account dot only when asked', (t) async {
      final c = free.byId('a0000003')!;
      await t.pumpWidget(wrap(AgentItem(card: c, onTap: () {}, project: free.projectOf(c), accountColor: const Color(0xFFA98BFF), showAccount: false)));
      expect(find.text('Northwind · app'), findsOneWidget);
      expect(find.byType(Dot), findsNothing);
    });
    testWidgets('usage strip: one meter per account, labels from the server', (t) async {
      await t.pumpWidget(wrap(UsageStrip(snap: solo)));
      expect(find.textContaining('Main  5h 18%'), findsOneWidget);
      await t.pumpWidget(wrap(UsageStrip(snap: free)));
      expect(find.textContaining('Studio  5h'), findsOneWidget);
      expect(find.textContaining('Overflow  5h'), findsOneWidget);
    });
  });
}
