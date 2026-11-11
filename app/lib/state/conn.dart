import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/loft_client.dart';
import '../data/models.dart';
import '../data/outbox.dart';
import '../data/pairing.dart';

/// Set once in main() after reading secure storage; changed by pairing/unpairing.
final pairingProvider = StateProvider<Pairing?>((ref) => null);

final clientProvider = Provider<LoftClient?>((ref) {
  final p = ref.watch(pairingProvider);
  if (p == null) return null;
  final c = LoftClient(p);
  ref.onDispose(c.close);
  return c;
});

/// "" = all, "work", "personal". Remembered.
final filterProvider = StateProvider<String>((ref) => '');

class Conn {
  final Snapshot snap;
  final bool loaded; // we have a snapshot (live or cached)
  final bool online;
  final bool connecting;
  final DateTime? lastUpdate;
  final String? error;
  final bool unpaired; // the server said the token is no good
  final int queued;

  const Conn({this.snap = Snapshot.empty, this.loaded = false, this.online = false, this.connecting = true, this.lastUpdate, this.error, this.unpaired = false, this.queued = 0});

  bool get offline => !online && !connecting;

  Conn copy({Snapshot? snap, bool? loaded, bool? online, bool? connecting, DateTime? lastUpdate, String? error, bool clearError = false, bool? unpaired, int? queued}) => Conn(
        snap: snap ?? this.snap,
        loaded: loaded ?? this.loaded,
        online: online ?? this.online,
        connecting: connecting ?? this.connecting,
        lastUpdate: lastUpdate ?? this.lastUpdate,
        error: clearError ? null : (error ?? this.error),
        unpaired: unpaired ?? this.unpaired,
        queued: queued ?? this.queued,
      );
}

/// Keeps one SSE stream open while the app is in front; reconnects with
/// backoff; keeps the last snapshot (also on disk) for the offline view;
/// flushes the outbox when the laptop is back.
class ConnController extends StateNotifier<Conn> {
  final LoftClient? client;
  StreamSubscription<Snapshot?>? _sub;
  Timer? _retry;
  int _backoff = 0;
  bool _paused = false;
  Outbox? _outbox;
  final _flushed = StreamController<String>.broadcast();

  /// Messages for the UI ("Sent 2 waiting messages").
  Stream<String> get notices => _flushed.stream;

  ConnController(this.client) : super(const Conn()) {
    _boot();
  }

  static const _cacheKey = 'loft.snapshot';
  static const _cacheAtKey = 'loft.snapshot.at';

  Future<void> _boot() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_cacheKey);
      if (raw != null && !state.loaded) {
        state = state.copy(snap: Snapshot.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>()), loaded: true, lastUpdate: DateTime.tryParse(p.getString(_cacheAtKey) ?? ''));
      }
    } catch (_) {}
    _outbox = await Outbox.load();
    state = state.copy(queued: _outbox!.items.length);
    connect();
  }

  void connect() {
    final c = client;
    if (c == null || _paused || !mounted) return;
    _retry?.cancel();
    _sub?.cancel();
    state = state.copy(connecting: !state.online);
    _sub = c.events().listen((snap) {
      if (snap != null) {
        state = state.copy(snap: snap, loaded: true, online: true, connecting: false, lastUpdate: DateTime.now(), clearError: true, unpaired: false);
        _cache(snap);
      } else if (!state.online) {
        state = state.copy(online: true, connecting: false, clearError: true);
      }
      if (_backoff != 0) {
        _backoff = 0;
      }
      _flush();
    }, onError: (Object e) {
      final unpaired = e is LoftError && e.unauthorized;
      _down(e is LoftError ? e.message : '$e', unpaired: unpaired);
    }, onDone: () => _down('The connection closed.'), cancelOnError: true);
  }

  DateTime _lastCache = DateTime(0);

  /// Keeps a copy of the last snapshot on disk (at most every 10 s) for the offline view.
  Future<void> _cache(Snapshot snap) async {
    if (DateTime.now().difference(_lastCache).inSeconds < 10) return;
    _lastCache = DateTime.now();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_cacheKey, jsonEncode(_snapToJson(snap)));
      await p.setString(_cacheAtKey, DateTime.now().toIso8601String());
    } catch (_) {}
  }

  static Map<String, dynamic> _snapToJson(Snapshot s) => {
        'cards': [
          for (final c in s.cards)
            {
              'id': c.id, 'kind': c.kind, 'name': c.name, 'work': c.work, 'col': c.col.name, 'state': c.state, 'detail': c.detail,
              'result': c.result, 'cwd': c.cwd, 'project': c.project, 'updated': c.updated?.toIso8601String(), 'live': c.live,
              'pinned': c.pinned, 'failed': c.failed,
            }
        ],
        'usage': {
          'work': {'five': s.work.five, 'seven': s.work.seven},
          'personal': {'five': s.personal.five, 'seven': s.personal.seven},
        },
        'dirs': s.dirs,
        'voice': s.voice,
      };

  void _down(String why, {bool unpaired = false}) {
    if (!mounted) return;
    state = state.copy(online: false, connecting: false, error: why, unpaired: unpaired);
    if (unpaired || _paused) return;
    _backoff = (_backoff == 0 ? 2 : _backoff * 2).clamp(2, 15);
    _retry = Timer(Duration(seconds: _backoff), connect);
  }

  /// Retry now (the banner's Retry button, pull to refresh).
  Future<void> retry() async {
    _backoff = 0;
    final c = client;
    if (c == null) return;
    state = state.copy(connecting: true);
    try {
      final s = await c.state();
      state = state.copy(snap: s, loaded: true, online: true, connecting: false, lastUpdate: DateTime.now(), clearError: true, unpaired: false);
    } on LoftError catch (e) {
      state = state.copy(online: false, connecting: false, error: e.message, unpaired: e.unauthorized);
      return;
    }
    connect();
  }

  void pause() {
    _paused = true;
    _retry?.cancel();
    _sub?.cancel();
    _sub = null;
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    connect();
  }

  /// Queue a send for when the laptop is back.
  Future<void> enqueue(OutboxItem i) async {
    _outbox ??= await Outbox.load();
    await _outbox!.add(i);
    state = state.copy(queued: _outbox!.items.length);
  }

  bool _flushing = false;
  Future<void> _flush() async {
    final c = client, ob = _outbox;
    if (c == null || ob == null || ob.items.isEmpty || _flushing) return;
    _flushing = true;
    try {
      final r = await ob.flush(c);
      if (r.sent > 0) _flushed.add('Sent ${r.sent} waiting ${r.sent == 1 ? 'message' : 'messages'}');
      for (final e in r.errors) {
        _flushed.add(e);
      }
      if (mounted) state = state.copy(queued: ob.items.length);
    } finally {
      _flushing = false;
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    _sub?.cancel();
    _flushed.close();
    super.dispose();
  }
}

final connProvider = StateNotifierProvider<ConnController, Conn>((ref) => ConnController(ref.watch(clientProvider)));
