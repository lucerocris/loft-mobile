import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'notify/watcher.dart';
import 'data/models.dart';
import 'screens/agent_screen.dart';
import 'screens/browser_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/inbox_screen.dart';
import 'screens/new_task_screen.dart';
import 'screens/pair_screen.dart';
import 'screens/projects_screen.dart';
import 'screens/terminal_screen.dart';
import 'state/conn.dart';
import 'state/session_view.dart';
import 'theme/theme.dart';

/// Chat <-> Terminal: a quick cross-fade, not a new screen sliding in.
Page<void> _fade(GoRouterState s, Widget child) => CustomTransitionPage(
      key: s.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 150),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      transitionsBuilder: (_, a, _, c) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: c),
    );

final _routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final paired = ref.read(pairingProvider) != null;
      if (!paired && state.matchedLocation != '/pair') return '/pair';
      if (paired && state.matchedLocation == '/pair') return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/pair', builder: (_, _) => const PairScreen()),
      GoRoute(path: '/', builder: (_, _) => const InboxScreen()),
      // An agent opens in the last view used (Chat by default); older Loft = no chat.
      GoRoute(path: '/agent/:id', pageBuilder: (_, s) {
        final id = s.pathParameters['id']!;
        final view = ref.read(sessionViewProvider);
        Widget w;
        if (ref.read(chatUnsupportedProvider)) {
          final needs = ref.read(connProvider).snap.byId(id)?.col == Col.needs;
          w = needs ? AgentScreen(id: id) : TerminalScreen(id: id);
        } else {
          w = view == SessionView.terminal ? TerminalScreen(id: id) : ChatScreen(id: id);
        }
        return MaterialPage(key: s.pageKey, child: w);
      }),
      GoRoute(path: '/chat/:id', pageBuilder: (_, s) => _fade(s, ChatScreen(id: s.pathParameters['id']!))),
      GoRoute(path: '/term/:id', pageBuilder: (_, s) => _fade(s, TerminalScreen(id: s.pathParameters['id']!))),
      GoRoute(path: '/ask/:id', builder: (_, s) => AgentScreen(id: s.pathParameters['id']!)),
      GoRoute(
        path: '/new',
        pageBuilder: (_, s) => MaterialPage(fullscreenDialog: true, child: NewTaskScreen(listen: s.uri.queryParameters['listen'] == '1')),
      ),
      GoRoute(path: '/projects', builder: (_, s) => ProjectsScreen(startNew: s.uri.queryParameters['new'] == '1', assignCard: s.uri.queryParameters['card'])),
      GoRoute(path: '/browser', builder: (_, _) => const BrowserHomeScreen()),
      GoRoute(path: '/browser/agent/:id', builder: (_, s) => LiveBrowserScreen.agent(id: s.pathParameters['id']!)),
      GoRoute(
        path: '/browser/sites/:account',
        builder: (_, s) => LiveBrowserScreen.sites(
          account: s.pathParameters['account']!,
          siteId: s.uri.queryParameters['site'],
          siteName: s.uri.queryParameters['name'],
        ),
      ),
      GoRoute(path: '/todo/:id', pageBuilder: (_, s) => MaterialPage(fullscreenDialog: true, child: NewTaskScreen(todoId: s.pathParameters['id']))),
    ],
  );
  ref.listen(pairingProvider, (_, _) => router.refresh());
  return router;
});

class LoftApp extends ConsumerStatefulWidget {
  final String? openCard;
  const LoftApp({super.key, this.openCard});
  @override
  ConsumerState<LoftApp> createState() => _LoftAppState();
}

class _LoftAppState extends ConsumerState<LoftApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Alerts.onOpen = (id) => ref.read(_routerProvider).push('/agent/$id');
    if (widget.openCard != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(_routerProvider).push('/agent/${widget.openCard}'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // The in-app stream only runs while Loft is on screen; the alerts service
    // (if on) keeps watching in the background.
    final c = ref.read(connProvider.notifier);
    if (s == AppLifecycleState.paused) c.pause();
    if (s == AppLifecycleState.resumed) c.resume();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Loft',
      debugShowCheckedModeBanner: false,
      theme: loftTheme(),
      darkTheme: loftTheme(),
      themeMode: ThemeMode.dark,
      routerConfig: ref.watch(_routerProvider),
    );
  }
}
