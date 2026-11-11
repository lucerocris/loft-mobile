import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'notify/watcher.dart';
import 'screens/agent_screen.dart';
import 'screens/inbox_screen.dart';
import 'screens/new_task_screen.dart';
import 'screens/pair_screen.dart';
import 'screens/terminal_screen.dart';
import 'state/conn.dart';
import 'theme/theme.dart';

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
      GoRoute(path: '/agent/:id', builder: (_, s) => AgentScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/term/:id', builder: (_, s) => TerminalScreen(id: s.pathParameters['id']!)),
      GoRoute(
        path: '/new',
        pageBuilder: (_, s) => MaterialPage(fullscreenDialog: true, child: NewTaskScreen(listen: s.uri.queryParameters['listen'] == '1')),
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
