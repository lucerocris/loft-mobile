/// The live browser on the phone: Loft's per-agent headless Chrome
/// (`/ws/browser/<id>`) and the Loft-wide Sites browser. Both speak the same
/// protocol (Loft loft/browser.py Viewer):
///
/// - binary frames in: one JPEG screencast frame each;
/// - text frames in: `{"type": "hello"|"url"|"err"|"toast"|"steps"|"saved"|...}`;
/// - text frames out: `{"type": "mouse", "kind": "mousePressed"|"mouseReleased"|
///   "mouseMoved"|"mouseWheel", "x", "y", "button", "clicks", "dx", "dy", "mods"}`
///   (x, y are 0..1 of the picture), `{"type": "key", "text"}` or
///   `{"type": "key", "key": "Enter"|"Backspace"|..., "mods"}`, `{"type": "nav", "url"}`,
///   `{"type": "back"}`, `{"type": "reload"}`, `{"type": "viewport", "mobile": bool}`.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// Where the picture sits in the viewer box: scaled to fit, centred sideways,
/// top-aligned (a page reads from the top).
Rect fitPicture(Size box, Size frame) {
  if (frame.width <= 0 || frame.height <= 0 || box.width <= 0 || box.height <= 0) return Rect.zero;
  final s = math.min(box.width / frame.width, box.height / frame.height);
  final w = frame.width * s, h = frame.height * s;
  return Rect.fromLTWH((box.width - w) / 2, 0, w, h);
}

/// A point in the viewer box as 0..1 of the picture. Null when it falls
/// outside the picture, unless [clamp] (drags that leave the picture).
Offset? toPageFraction(Offset local, Rect picture, {bool clamp = false}) {
  if (picture.isEmpty) return null;
  final fx = (local.dx - picture.left) / picture.width;
  final fy = (local.dy - picture.top) / picture.height;
  if (!clamp && (fx < 0 || fx > 1 || fy < 0 || fy > 1)) return null;
  return Offset(fx.clamp(0.0, 1.0), fy.clamp(0.0, 1.0));
}

/// A finger drag on the picture as a mouse-wheel delta in page pixels.
/// Dragging up scrolls the page down (positive dy), like a touch screen.
/// [pageWidth] is the page's width in CSS pixels (the picture's width in
/// device pixels divided by the device scale factor).
Offset wheelFor(Offset drag, Rect picture, double pageWidth) {
  if (picture.isEmpty) return Offset.zero;
  final k = pageWidth / picture.width;
  return Offset(-drag.dx * k, -drag.dy * k);
}

/// How to turn the phone keyboard field's change from [before] to [after]
/// into key events: [back] Backspaces, then type [insert]. Keeps the common
/// prefix, so autocorrect replacing a word deletes and retypes only that word.
({int back, String insert}) keyDiff(String before, String after) {
  var i = 0;
  final n = math.min(before.length, after.length);
  while (i < n && before.codeUnitAt(i) == after.codeUnitAt(i)) {
    i++;
  }
  return (back: before.length - i, insert: after.substring(i));
}

/// Outgoing messages, as JSON strings.
abstract final class BrowserMsg {
  static String _m(Map<String, Object?> m) => jsonEncode(m);

  static String mouse(String kind, Offset at, {String button = 'left', int clicks = 1, Offset? wheel}) => _m({
        'type': 'mouse',
        'kind': kind,
        'x': _r(at.dx),
        'y': _r(at.dy),
        if (kind == 'mousePressed' || kind == 'mouseReleased') ...{'button': button, 'clicks': clicks},
        if (wheel != null) ...{'dx': wheel.dx.round(), 'dy': wheel.dy.round()},
      });

  static String text(String t) => _m({'type': 'key', 'text': t});
  static String key(String k, {int mods = 0}) => _m({'type': 'key', 'key': k, if (mods != 0) 'mods': mods});
  static String nav(String url) => _m({'type': 'nav', 'url': url});
  static String back() => _m({'type': 'back'});
  static String reload() => _m({'type': 'reload'});
  static String site(String id) => _m({'type': 'site', 'id': id});
  static String viewport(bool mobile) => _m({'type': 'viewport', 'mobile': mobile});

  static double _r(double v) => (v * 10000).roundToDouble() / 10000;
}

/// What to show in the address bar: no scheme for http(s), the rest as is.
String shortUrl(String url) {
  final u = url.trim();
  if (u.isEmpty || u == 'about:blank') return '';
  return u.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'/$'), '');
}

/// A site in an account's Sites browser (Loft › Browser).
class SiteEntry {
  final String id, name, url;
  /// The Loft account whose signed-in browser holds it.
  final String account;
  /// A hint: Loft's profile has unexpired cookies for the host (null = unknown).
  final bool? signedIn;
  const SiteEntry({required this.id, required this.name, required this.url, this.account = '', this.signedIn});

  String get host => Uri.tryParse(url.contains('://') ? url : 'https://$url')?.host ?? url;

  factory SiteEntry.fromJson(Map<String, dynamic> j, {String account = ''}) {
    final url = '${j['url'] ?? ''}';
    final host = Uri.tryParse(url.contains('://') ? url : 'https://$url')?.host ?? url;
    final name = '${j['name'] ?? ''}';
    return SiteEntry(
      id: '${j['id'] ?? host}',
      name: name.isNotEmpty ? name : host,
      url: url,
      account: '${j['account'] ?? account}',
      signedIn: j['signedIn'] is bool ? j['signedIn'] as bool : null,
    );
  }
}

/// One Loft account's signed-in browser and its sites (an entry of `GET /api/sites`).
class SitesAccount {
  final String id, label;
  final int? color;
  final List<SiteEntry> sites;
  /// Its headless browser is running now.
  final bool running;
  /// The profile is open in a normal Chrome window on the desktop: no stream until it closes.
  final bool window;
  const SitesAccount({required this.id, this.label = '', this.color, this.sites = const [], this.running = false, this.window = false});

  factory SitesAccount.fromJson(Map<String, dynamic> j, {String? id}) {
    final acc = '${id ?? j['account'] ?? j['id'] ?? ''}';
    final b = j['browser'] is Map ? (j['browser'] as Map) : const {};
    final hex = '${j['hex'] ?? ''}'.replaceFirst('#', '');
    return SitesAccount(
      id: acc,
      label: '${j['label'] ?? acc}',
      color: RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex) ? 0xFF000000 | int.parse(hex, radix: 16) : null,
      sites: [for (final s in (j['sites'] as List? ?? const [])) if (s is Map) SiteEntry.fromJson(s.cast<String, dynamic>(), account: acc)],
      running: b['running'] == true,
      window: b['window'] == true,
    );
  }
}

/// An agent with a Loft browser, as `GET /api/sites` lists it.
class BrowserAgent {
  final String id, name, account, url;
  final bool live;
  /// Whose signed-in sites its browser started with (null = a plain web-project browser).
  final String? sitesAccount;
  const BrowserAgent({required this.id, this.name = '', this.account = '', this.url = '', this.live = false, this.sitesAccount});
  factory BrowserAgent.fromJson(Map<String, dynamic> j) => BrowserAgent(
        id: '${j['id']}',
        name: '${j['name'] ?? ''}',
        account: '${j['account'] ?? ''}',
        url: '${j['url'] ?? ''}',
        live: j['live'] == true,
        sitesAccount: j['sitesAccount'] is String ? j['sitesAccount'] as String : null,
      );
}

/// `GET /api/sites` (Loft docs/browser-protocol.md).
class SitesInfo {
  final List<SitesAccount> accounts;
  final List<BrowserAgent> agents;
  /// Loft found a Chrome to run (false = no browser on the laptop).
  final bool chrome;
  const SitesInfo({this.accounts = const [], this.agents = const [], this.chrome = true});

  List<SiteEntry> get sites => [for (final a in accounts) ...a.sites];
  SitesAccount? account(String id) => accounts.where((a) => a.id == id).firstOrNull;

  /// Accepts `{accounts: [{account, sites, browser}], agents, chrome}` (the
  /// documented shape), `{accounts: {id: [sites]}}` and `{sites: [...]}`.
  factory SitesInfo.fromJson(Object? j) {
    final accounts = <SitesAccount>[];
    final agents = <BrowserAgent>[];
    var chrome = true;
    if (j is Map) {
      final accs = j['accounts'];
      if (accs is List) {
        for (final a in accs) {
          if (a is Map) accounts.add(SitesAccount.fromJson(a.cast<String, dynamic>()));
        }
      } else if (accs is Map) {
        for (final e in accs.entries) {
          final v = e.value;
          accounts.add(SitesAccount.fromJson(v is Map ? v.cast<String, dynamic>() : {'sites': v}, id: '${e.key}'));
        }
      }
      if (j['sites'] is List) accounts.add(SitesAccount.fromJson({'sites': j['sites']}, id: ''));
      for (final a in (j['agents'] as List? ?? const [])) {
        if (a is Map) agents.add(BrowserAgent.fromJson(a.cast<String, dynamic>()));
      }
      chrome = j['chrome'] != false;
    } else if (j is List) {
      accounts.add(SitesAccount.fromJson({'sites': j}, id: ''));
    }
    return SitesInfo(accounts: accounts, agents: agents, chrome: chrome);
  }
}
