import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../data/browser.dart';
import '../data/loft_client.dart';

/// One open browser socket. [stream] yields `List<int>` (JPEG frames) and `String` (JSON events).
abstract class BrowserLink {
  Stream<dynamic> get stream;
  void send(String text);
  Future<void> close();
}

class WsBrowserLink implements BrowserLink {
  final WebSocket ws;
  WsBrowserLink(this.ws);
  @override
  Stream<dynamic> get stream => ws;
  @override
  void send(String text) {
    if (ws.readyState == WebSocket.open) ws.add(text);
  }

  @override
  Future<void> close() => ws.close();
}

enum BrowserStatus { connecting, live, closed, refused }

typedef BrowserConnector = Future<BrowserLink> Function();

/// A live browser: the latest decoded frame, the page's address, errors and
/// toasts from Loft, and the input going back. Shared by the agent's browser
/// and the Sites browser.
class BrowserSession extends ChangeNotifier {
  final BrowserConnector connector;
  /// Sent once the socket is up (the Sites browser opens a site this way:
  /// `BrowserMsg.site(id)`).
  final String? openMsg;

  BrowserSession(this.connector, {this.openMsg});

  BrowserStatus status = BrowserStatus.connecting;
  /// Why it closed or was refused.
  String? message;
  ui.Image? frame;
  String url = '';
  bool mobile = false;
  /// The agent drives it through Loft's tools (hello.mcp).
  bool agentDriven = false;
  List<int> ports = const [];
  /// Sites browser: the account entry from hello/sites (the sites and sign-in hints).
  SitesAccount? sitesAccount;
  /// Sites browser: the profile is open in a window on the desktop instead.
  bool inWindow = false;
  final errors = <String>[];
  /// The page's width in CSS pixels, when Loft says (hello/meta.deviceWidth).
  double? _pageWidth;

  final _toasts = StreamController<({String text, bool error})>.broadcast();
  Stream<({String text, bool error})> get toasts => _toasts.stream;

  BrowserLink? _link;
  StreamSubscription? _sub;
  bool _disposed = false;
  Uint8List? _pending;
  bool _decoding = false;
  /// The viewport came from Loft or the user, not guessed from the picture.
  bool _viewportKnown = false;
  int frames = 0;

  /// CSS pixels across the page, for turning drags into wheel deltas.
  double get pageWidth {
    if (_pageWidth != null) return _pageWidth!;
    final w = frame?.width.toDouble() ?? 1280;
    return mobile ? w / 2 : w; // mobile emulation renders at 2x
  }

  Future<void> start() async {
    await _sub?.cancel();
    await _link?.close().catchError((_) {});
    _link = null;
    message = null;
    _set(BrowserStatus.connecting, null);
    try {
      final link = await connector();
      if (_disposed) {
        await link.close();
        return;
      }
      _link = link;
      inWindow = false;
      _sub = link.stream.listen(_onData, onDone: () => _set(BrowserStatus.closed, message ?? 'The browser closed.'), onError: (Object e) => _set(BrowserStatus.closed, 'Connection lost.'));
      _set(BrowserStatus.live, null);
      if (openMsg != null) send(openMsg!);
    } on LoftError catch (e) {
      // 404/403: this Loft doesn't share the browser with the phone (older or desktop-only).
      if (e.status == 404 || e.status == 403 || e.status == 405) {
        _set(BrowserStatus.refused, e.status == 403 ? 'Loft on the laptop keeps this browser to the desktop.' : 'This Loft doesn\'t share its browser with the phone yet. Update Loft on the laptop.');
      } else {
        _set(BrowserStatus.closed, e.message);
      }
    } catch (e) {
      _set(BrowserStatus.closed, '$e');
    }
  }

  void _set(BrowserStatus s, String? m) {
    if (_disposed) return;
    status = s;
    message = m;
    notifyListeners();
  }

  void _onData(dynamic m) {
    if (m is String) return _onEvent(m);
    if (m is List<int>) {
      _pending = m is Uint8List ? m : Uint8List.fromList(m);
      _decodeNext();
    }
  }

  /// Decodes the newest frame only; frames that arrive while one decodes are dropped.
  Future<void> _decodeNext() async {
    if (_decoding || _pending == null) return;
    _decoding = true;
    final bytes = _pending!;
    _pending = null;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final fi = await codec.getNextFrame();
      codec.dispose();
      if (_disposed) {
        fi.image.dispose();
      } else {
        final old = frame;
        frame = fi.image;
        // Loft doesn't say which viewport the page is in: a tall picture is the phone one.
        if (!_viewportKnown) mobile = frame!.height > frame!.width;
        frames++;
        notifyListeners();
        old?.dispose();
      }
    } catch (_) {
      // a bad frame: skip it
    } finally {
      _decoding = false;
    }
    if (_pending != null && !_disposed) _decodeNext();
  }

  void _onEvent(String raw) {
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (j['type']) {
      case 'hello':
        agentDriven = j['mcp'] == true;
        if (j['sites'] is List) sitesAccount = SitesAccount.fromJson(j);
        ports = [for (final p in (j['ports'] as List? ?? const [])) if (p is int) p];
        if (j['mobile'] is bool) {
          mobile = j['mobile'] as bool;
          _viewportKnown = true;
        }
        if (j['url'] is String) url = j['url'] as String;
        _meta(j);
      case 'meta':
        if (j['mobile'] is bool) {
          mobile = j['mobile'] as bool;
          _viewportKnown = true;
        }
        _meta(j);
      case 'sites':
        sitesAccount = SitesAccount.fromJson(j);
      case 'window':
        inWindow = true;
        message = 'This browser is open in a window on the laptop. Close that window to watch it here.';
      case 'url':
        url = '${j['url'] ?? ''}';
      case 'err':
        errors.add('${j['text'] ?? 'error'}');
        if (errors.length > 50) errors.removeAt(0);
      case 'toast':
        _toasts.add((text: '${j['text'] ?? ''}', error: j['err'] == true));
        // An error before the first picture is why it couldn't open (the socket closes next).
        if (j['err'] == true && frame == null) message = '${j['text'] ?? ''}';
      case 'bye':
      case 'closed':
        message = '${j['text'] ?? j['message'] ?? 'The browser closed.'}';
      default:
        return;
    }
    if (!_disposed) notifyListeners();
  }

  void _meta(Map<String, dynamic> j) {
    final m = j['meta'] is Map ? (j['meta'] as Map) : j;
    final w = m['deviceWidth'] ?? m['width'];
    if (w is num && w > 0) _pageWidth = w.toDouble();
  }

  void send(String msg) => _link?.send(msg);

  /// Tests: show [img] as the current frame without decoding a JPEG.
  @visibleForTesting
  void debugShowFrame(ui.Image img) {
    frame = img;
    notifyListeners();
  }

  void tap(ui.Offset at) {
    send(BrowserMsg.mouse('mouseMoved', at));
    send(BrowserMsg.mouse('mousePressed', at));
    send(BrowserMsg.mouse('mouseReleased', at));
  }

  void scroll(ui.Offset at, ui.Offset wheel) {
    if (wheel == ui.Offset.zero) return;
    send(BrowserMsg.mouse('mouseWheel', at, wheel: wheel));
  }

  void navigate(String u) {
    final t = u.trim();
    if (t.isEmpty) return;
    url = t;
    send(BrowserMsg.nav(t));
    notifyListeners();
  }

  void setMobile(bool on) {
    mobile = on;
    _viewportKnown = true;
    _pageWidth = null; // the page changes size; Loft resends meta if it knows
    send(BrowserMsg.viewport(on));
    notifyListeners();
  }

  /// Types what the phone keyboard field changed.
  void typeDiff(String before, String after) {
    final d = keyDiff(before, after);
    for (var i = 0; i < d.back; i++) {
      send(BrowserMsg.key('Backspace'));
    }
    if (d.insert.isEmpty) return;
    // Newlines are Enter presses; the rest is inserted text.
    final parts = d.insert.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) send(BrowserMsg.key('Enter'));
      if (parts[i].isNotEmpty) send(BrowserMsg.text(parts[i]));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _link?.close().catchError((_) {});
    _toasts.close();
    frame?.dispose();
    super.dispose();
  }
}
