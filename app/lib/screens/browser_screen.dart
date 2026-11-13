import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/browser.dart';
import '../data/loft_client.dart';
import '../data/models.dart';
import '../state/browser_session.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../widgets/browser_view.dart';
import '../widgets/common.dart';

/// Socket paths for the two kinds of live browser.
String agentBrowserPath(String id) => '/ws/browser/$id';
String sitesBrowserPath(String account) => '/ws/sites/${Uri.encodeComponent(account.isEmpty ? 'default' : account)}';

/// GET /api/sites (null while loading; refused = an older or desktop-only Loft).
class SitesState {
  final SitesInfo? info;
  final bool refused;
  final String? error;
  const SitesState({this.info, this.refused = false, this.error});
}

final sitesProvider = FutureProvider.autoDispose<SitesState>((ref) async {
  final c = ref.watch(clientProvider);
  if (c == null) return const SitesState(info: SitesInfo());
  try {
    return SitesState(info: await c.sites());
  } on LoftError catch (e) {
    if (e.status == 404 || e.status == 403) return const SitesState(refused: true);
    return SitesState(error: e.message);
  }
});

/// Main navigation › Browser: each Loft account's signed-in browser with its
/// sites (Loft › Browser), and the agents' live browsers.
class BrowserHomeScreen extends ConsumerWidget {
  const BrowserHomeScreen({super.key});

  void _openSites(BuildContext context, String account, {SiteEntry? site}) => context.push(Uri(
        path: '/browser/sites/${Uri.encodeComponent(account)}',
        queryParameters: {if (site != null) ...{'site': site.id, 'name': site.name}},
      ).toString());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(connProvider).snap;
    final sites = ref.watch(sitesProvider);
    final st = sites.valueOrNull;
    final info = st?.info;
    // Agents with a browser: the snapshot's badges, plus any /api/sites knows of.
    final agents = snap.cards.where((c) => c.isAgent && c.hasBrowser).toList()..sort(byPinThenNewest);
    final listed = {for (final a in info?.agents ?? const <BrowserAgent>[]) a.id: a};
    for (final a in listed.values) {
      if (!agents.any((c) => c.id == a.id) && snap.byId(a.id) != null) agents.add(snap.byId(a.id)!);
    }

    Widget sitesBody() {
      if (sites.isLoading && st == null) return const Padding(padding: EdgeInsets.all(S.s6), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
      if (st == null || st.error != null) return _Note(icon: LucideIcons.wifiOff, text: st?.error ?? 'Couldn\'t load your sites.');
      if (st.refused) return const _Note(icon: LucideIcons.monitorOff, text: 'Signed-in sites need a newer Loft on the laptop.');
      final accs = info!.accounts;
      if (!info.chrome) return const _Note(icon: LucideIcons.monitorOff, text: 'Loft found no Chrome on the laptop. Install Chrome or Chromium there.');
      if (accs.isEmpty) return const _Note(icon: LucideIcons.globe, text: 'No accounts in Loft yet.');
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final a in accs) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, S.s3, 12, S.s1),
            child: Row(children: [
              Dot(Color(a.color ?? snap.account(a.id)?.color ?? 0xFF6E737B), size: 6),
              const SizedBox(width: 6),
              Expanded(child: Text(a.label.isEmpty ? snap.accountLabel(a.id) : a.label, style: T.label)),
              if (a.window) Text('open in a window on ${ref.watch(pairingProvider)?.name ?? 'the laptop'}', style: T.caption.copyWith(color: C.needs))
              else if (a.running) const Text('running', style: T.caption),
            ]),
          ),
          for (final s in a.sites)
            _Row(
              icon: LucideIcons.globe,
              title: s.name,
              sub: [s.host, if (s.signedIn == true) 'signed in' else if (s.signedIn == false) 'signed out'].join(' · '),
              trailing: s.signedIn == false ? const Dot(C.needs, size: 6) : null,
              onTap: () => _openSites(context, a.id, site: s),
            ),
          _Row(
            icon: LucideIcons.appWindow,
            title: 'Open the browser',
            sub: a.sites.isEmpty ? 'No sites yet: add them in Loft › Browser on the laptop' : 'Where you sign in to ${a.label.isEmpty ? 'these' : '${a.label}\'s'} sites',
            onTap: () => _openSites(context, a.id),
          ),
        ],
      ]);
    }

    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.all(S.s1),
              child: Row(children: [
                IconBtn(LucideIcons.arrowLeft, tooltip: 'Back', onTap: () => context.pop()),
                const SizedBox(width: S.s1),
                const Expanded(child: Text('Browser', style: T.screenTitle)),
                IconBtn(LucideIcons.refreshCw, tooltip: 'Refresh', size: 20, onTap: () => ref.invalidate(sitesProvider)),
              ]),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: C.t1,
              backgroundColor: C.raised,
              onRefresh: () async => ref.invalidate(sitesProvider),
              child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(S.s4, 0, S.s4, S.s6), children: [
                const _Section('Signed-in sites'),
                sitesBody(),
                _Section('Agent browsers', count: agents.length),
                if (agents.isEmpty)
                  const _Note(icon: LucideIcons.bot, text: 'No agent has a browser. Agents on web projects, or on an account with sites, get one.')
                else
                  for (final c in agents)
                    _Row(
                      icon: LucideIcons.appWindow,
                      title: c.name,
                      sub: [
                        _or(shortUrl(c.browser?.url ?? listed[c.id]?.url ?? ''), c.folderName),
                        if (c.browser?.summary.isNotEmpty ?? false) c.browser!.summary,
                      ].join(' · '),
                      lead: snap.account(c.account) == null ? null : Dot(Color(snap.account(c.account)!.color), size: 6),
                      trailing: (c.browser?.live ?? listed[c.id]?.live ?? false) ? const Text('live', style: T.caption) : null,
                      onTap: () => context.push('/browser/agent/${c.id}'),
                    ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// One live browser full screen: an agent's (by card id) or a site in the
/// account's Sites browser.
class LiveBrowserScreen extends ConsumerStatefulWidget {
  final String? agentId;
  /// Sites browser: the Loft account, and the site to open (null = as it is).
  final String? account, siteId, siteName;
  const LiveBrowserScreen.agent({super.key, required String id})
      : agentId = id,
        account = null,
        siteId = null,
        siteName = null;
  const LiveBrowserScreen.sites({super.key, required String this.account, this.siteId, this.siteName}) : agentId = null;

  @override
  ConsumerState<LiveBrowserScreen> createState() => _LiveBrowserScreenState();
}

class _LiveBrowserScreenState extends ConsumerState<LiveBrowserScreen> {
  late final BrowserSession _session;

  @override
  void initState() {
    super.initState();
    final path = widget.agentId != null ? agentBrowserPath(widget.agentId!) : sitesBrowserPath(widget.account ?? '');
    _session = BrowserSession(() async {
      final c = ref.read(clientProvider);
      if (c == null) throw const LoftError('Not paired.');
      final WebSocket ws = await c.browserSocket(path);
      return WsBrowserLink(ws);
    }, openMsg: widget.siteId == null ? null : BrowserMsg.site(widget.siteId!));
    _session.start();
  }

  @override
  void dispose() {
    _session.dispose(); // closes the socket; the browser keeps running on the laptop
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(connProvider).snap;
    final card = widget.agentId == null ? null : snap.byId(widget.agentId!);
    final acc = snap.account(card?.account ?? widget.account);
    final title = card?.name ?? widget.siteName ?? '${acc?.label ?? widget.account} sites';
    final sub = card != null
        ? [if (snap.multiAccount) snap.accountLabel(card.account), card.folderName].join(' · ')
        : [if (acc != null) acc.label, 'signed-in browser'].join(' · ');
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(S.s1),
            child: Row(children: [
              IconBtn(LucideIcons.arrowLeft, tooltip: 'Back (the browser keeps running)', onTap: () => context.pop()),
              const SizedBox(width: S.s1),
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.screenTitle),
                  const SizedBox(height: 2),
                  Row(children: [
                    if (acc != null) ...[Dot(Color(acc.color), size: 6), const SizedBox(width: 6)],
                    Flexible(child: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t2))),
                  ]),
                ]),
              ),
              ListenableBuilder(
                listenable: _session,
                builder: (_, _) => Padding(
                  padding: const EdgeInsets.only(right: S.s3),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Dot(switch (_session.status) {
                      BrowserStatus.live => C.ok,
                      BrowserStatus.connecting => C.t3,
                      _ => C.failed,
                    }, size: 6),
                    const SizedBox(width: 6),
                    Text(
                        switch (_session.status) {
                          BrowserStatus.live => _session.agentDriven ? 'live · agent' : 'live',
                          BrowserStatus.connecting => 'opening',
                          BrowserStatus.refused => 'not shared',
                          BrowserStatus.closed => 'closed',
                        },
                        style: T.caption),
                  ]),
                ),
              ),
            ]),
          ),
          Expanded(child: BrowserViewer(session: _session)),
        ]),
      ),
    );
  }
}

String _or(String a, String b) => a.isEmpty ? b : a;

class _Section extends StatelessWidget {
  final String label;
  final int? count;
  const _Section(this.label, {this.count});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, S.s4, 12, S.s1),
        child: Row(children: [
          Text(label, style: T.label),
          if (count != null && count! > 0) ...[const SizedBox(width: S.s2), Text('$count', style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3))],
        ]),
      );
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title, sub;
  final Widget? lead, trailing;
  final VoidCallback onTap;
  const _Row({required this.icon, required this.title, required this.sub, this.lead, this.trailing, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(R.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(children: [
            Icon(icon, size: 18, color: C.t2),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.rowTitle),
                Row(children: [
                  if (lead != null) ...[lead!, const SizedBox(width: 6)],
                  Expanded(child: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.secondary.copyWith(color: C.t3))),
                ]),
              ]),
            ),
            if (trailing != null) ...[trailing!, const SizedBox(width: S.s2)],
            const Icon(LucideIcons.chevronRight, size: 18, color: C.t3),
          ]),
        ),
      );
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Note({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, S.s2, 12, S.s2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: C.t3),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: T.secondary)),
        ]),
      );
}
