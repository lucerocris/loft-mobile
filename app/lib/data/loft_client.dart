import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'chat.dart';
import 'models.dart';
import 'pairing.dart';
import 'sse.dart';

class LoftError implements Exception {
  final int? status;
  final String message;
  const LoftError(this.message, {this.status});

  /// Network trouble (laptop asleep, Tailscale off), as opposed to the server saying no.
  bool get offline => status == null;
  bool get unauthorized => status == 401 || status == 403;
  @override
  String toString() => message;
}

class Ping {
  final String host, version;
  final bool voice;
  const Ping(this.host, this.version, this.voice);
}

/// The Loft server API over the tailnet (see server.py and PLAN.md).
class LoftClient {
  final Pairing pairing;
  final http.Client _http;
  final Duration timeout;

  LoftClient(this.pairing, {http.Client? client, this.timeout = const Duration(seconds: 8)}) : _http = client ?? http.Client();

  Map<String, String> get _json => {...pairing.auth, 'Content-Type': 'application/json'};

  Future<dynamic> _decode(http.Response r) async {
    dynamic j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      j = null;
    }
    if (r.statusCode >= 400) {
      final msg = j is Map ? (j['message'] ?? j['error'] ?? 'Error ${r.statusCode}') : 'Error ${r.statusCode}';
      throw LoftError(r.statusCode == 401 ? 'This phone isn\'t paired any more. Pair it again from Loft on the laptop.' : '$msg', status: r.statusCode);
    }
    return j;
  }

  Future<dynamic> _get(String path, {Duration? t}) async {
    try {
      return _decode(await _http.get(pairing.http(path), headers: pairing.auth).timeout(t ?? timeout));
    } on LoftError {
      rethrow;
    } catch (e) {
      throw LoftError('Can\'t reach ${pairing.name}: ${_short(e)}');
    }
  }

  Future<dynamic> _post(String path, Object? body, {Duration? t}) async {
    try {
      return _decode(await _http.post(pairing.http(path), headers: _json, body: jsonEncode(body ?? {})).timeout(t ?? timeout));
    } on LoftError {
      rethrow;
    } catch (e) {
      throw LoftError('Can\'t reach ${pairing.name}: ${_short(e)}');
    }
  }

  Future<dynamic> _send(String method, String path, Object? body, {Duration? t}) async {
    try {
      final req = http.Request(method, pairing.http(path))
        ..headers.addAll(_json)
        ..body = jsonEncode(body ?? {});
      final res = await http.Response.fromStream(await _http.send(req).timeout(t ?? timeout));
      return _decode(res);
    } on LoftError {
      rethrow;
    } catch (e) {
      throw LoftError('Can\'t reach ${pairing.name}: ${_short(e)}');
    }
  }

  static String _short(Object e) {
    if (e is TimeoutException) return 'timed out';
    if (e is SocketException) return e.osError?.message ?? e.message;
    return '$e';
  }

  Future<Ping> ping() async {
    final j = await _get('/api/ping', t: const Duration(seconds: 5)) as Map;
    return Ping('${j['host']}', '${j['version']}', j['voice'] == true);
  }

  Future<Snapshot> state() async => Snapshot.fromJson((await _get('/api/state') as Map).cast<String, dynamic>());

  Future<List<TimelineEntry>> timeline(String id) async =>
      [for (final e in (await _get('/api/timeline/$id') as List)) TimelineEntry.fromJson((e as Map).cast<String, dynamic>())];

  /// GET `/api/cards/<id>/messages`: the session as chat items. [after] = only
  /// what is new since that cursor (pass [session] too); [before] = an older page.
  /// A 404 for a card that exists means the laptop runs an older Loft.
  Future<ChatPage> messages(String id, {int? after, int? before, String? session, int limit = 60}) async {
    final q = <String, String>{'limit': '$limit', 'after': ?after?.toString(), 'before': ?before?.toString(), 'session': ?session};
    final j = await _get(Uri(path: '/api/cards/$id/messages', queryParameters: q).toString());
    return ChatPage.fromJson((j as Map).cast<String, dynamic>());
  }

  /// POST `/api/cards/<id>/answer`: pick on the agent's picker. [answers] for an
  /// AskUserQuestion, [permission] (the option number) for a permission or plan
  /// prompt. 409 = the agent is no longer waiting on [tool].
  Future<String> answer(String id, {required String tool, List<Map<String, dynamic>>? answers, int? permission}) async {
    final j = await _post('/api/cards/$id/answer', {'tool': tool, 'answers': ?answers, 'permission': ?permission}, t: const Duration(seconds: 45));
    return '${(j as Map)['message']}';
  }

  /// POST /api/cards — Start now or Save to Todo. Returns the server message
  /// ("started 1a2b3c4d …" when started).
  /// [account] is an account id, "auto" or "" (let the server pick: the
  /// project's default, else Loft's). [project] is only sent when set.
  Future<String> create({required String prompt, required String account, required String cwd, required bool start, String title = '', String? project}) async {
    final j = await _post(
        '/api/cards',
        {'prompt': prompt, 'title': title, 'account': account, 'cwd': cwd, 'start': start, 'project': ?project},
        t: const Duration(seconds: 60));
    return '${(j as Map)['message']}';
  }

  /// POST `/api/cards/<id>/project`: pin a card to a project by hand; null clears
  /// it (the folder match applies again).
  Future<String> setCardProject(String id, String? project) => act(id, 'project', {'project': project});

  Future<Project> createProject(Project p) async {
    final j = await _post('/api/projects', p.toJson()) as Map;
    return Project.fromJson(((j['project'] is Map ? j['project'] : j) as Map).cast<String, dynamic>(), 0);
  }

  Future<void> updateProject(String id, Map<String, dynamic> changes) => _send('PATCH', '/api/projects/$id', changes);

  Future<void> deleteProject(String id) => _send('DELETE', '/api/projects/$id', null);

  /// POST `/api/cards/<id>/<action>`: reply, start, stop, archive, pin, rename, account, prompt.
  Future<String> act(String id, String action, [Map<String, dynamic> body = const {}]) async {
    final j = await _post('/api/cards/$id/$action', body, t: const Duration(seconds: 60));
    return '${(j as Map)['message']}';
  }

  Future<String> reply(String id, String text) => act(id, 'reply', {'text': text});

  /// Whole-clip transcription (fallback when the live stream isn't possible).
  Future<String> transcribe(List<int> audio, String contentType) async {
    try {
      final r = await _http
          .post(pairing.http('/api/voice'), headers: {...pairing.auth, 'Content-Type': contentType}, body: audio)
          .timeout(const Duration(seconds: 30));
      return '${(await _decode(r) as Map)['text'] ?? ''}';
    } on LoftError {
      rethrow;
    } catch (e) {
      throw LoftError('Can\'t reach ${pairing.name}: ${_short(e)}');
    }
  }

  /// GET /api/events: the full snapshot whenever it changes; null = heartbeat.
  Stream<Snapshot?> events() async* {
    final req = http.Request('GET', pairing.http('/api/events'))..headers.addAll({...pairing.auth, 'Accept': 'text/event-stream'});
    final http.StreamedResponse res;
    try {
      res = await _http.send(req).timeout(timeout);
    } catch (e) {
      throw LoftError('Can\'t reach ${pairing.name}: ${_short(e)}');
    }
    if (res.statusCode != 200) {
      await res.stream.drain<void>().catchError((_) {});
      throw LoftError(res.statusCode == 401 ? 'This phone isn\'t paired any more.' : 'Error ${res.statusCode}', status: res.statusCode);
    }
    // The server pings every 2 s; silence for 10 s means the link is gone.
    await for (final ev in sseEvents(res.stream).timeout(const Duration(seconds: 10))) {
      yield ev == null ? null : Snapshot.fromJson((jsonDecode(ev.data) as Map).cast<String, dynamic>());
    }
  }

  Future<WebSocketChannel> _ws(String path) async {
    final ch = IOWebSocketChannel.connect(pairing.ws(path), headers: pairing.auth, connectTimeout: const Duration(seconds: 6), pingInterval: const Duration(seconds: 20));
    await ch.ready;
    return ch;
  }

  /// WebSocket `/ws/term/<id>`: binary = pty bytes; text JSON = resize / input.
  Future<WebSocketChannel> terminal(String id) => _ws('/ws/term/$id');

  /// WebSocket /ws/voice: send PCM16 16 kHz mono frames, then {"type":"stop"}.
  Future<WebSocketChannel> voice() => _ws('/ws/voice');

  void close() => _http.close();
}
