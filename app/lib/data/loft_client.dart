import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'browser.dart';
import 'chat.dart';
import 'fs.dart';
import 'models.dart';
import 'pairing.dart';
import 'sse.dart';

/// POST /api/bulk's answer: what happened, and to which cards.
class BulkResult {
  final String message;
  final int count;
  final List<String> ids;
  const BulkResult(this.message, this.count, this.ids);
}

/// GET /api/assistant: `{id, card, account, running}`; [id] is null before the
/// first message (or after a reset).
class AssistantInfo {
  final String? id;
  final AgentCard? card;
  final String? account;
  final bool running;
  const AssistantInfo({this.id, this.card, this.account, this.running = false});

  factory AssistantInfo.fromJson(Map<String, dynamic> j) => AssistantInfo(
        id: j['id'] is String && (j['id'] as String).isNotEmpty ? j['id'] as String : null,
        card: j['card'] is Map ? AgentCard.fromJson((j['card'] as Map).cast<String, dynamic>()) : null,
        account: j['account'] is String ? j['account'] as String : null,
        running: j['running'] == true,
      );
}

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

  /// POST `/api/cards/<id>/rename` with `{title?, summary?}`. The title also goes
  /// as `name`, which older Loft reads (it ignores the rest).
  Future<String> rename(String id, {String? title, String? summary}) =>
      act(id, 'rename', {'title': ?title, 'name': ?title, 'summary': ?summary});

  /// POST `/api/cards/<id>/describe`: Loft writes a new title and summary from the
  /// session's first prompt. 404 = an older Loft.
  Future<({String title, String? summary})> describe(String id, {bool keepTitle = false}) async {
    final j = await _post('/api/cards/$id/describe', {'keepTitle': keepTitle}, t: const Duration(seconds: 60)) as Map;
    final s = j['summary'];
    return (title: '${j['title'] ?? ''}', summary: s is String && s.isNotEmpty ? s : null);
  }

  /// POST `/api/bulk`: archive or stop many agents at once. [ids] wins over [filter].
  Future<BulkResult> bulk(String action, {String filter = 'done', List<String>? ids}) async {
    final j = await _post('/api/bulk', {'action': action, 'filter': filter, 'ids': ?ids}, t: const Duration(seconds: 90)) as Map;
    return BulkResult('${j['message'] ?? ''}', j['count'] is int ? j['count'] as int : 0, [for (final i in (j['ids'] as List? ?? const [])) '$i']);
  }

  /// GET `/api/assistant`: the Loft Assistant's session. null = an older Loft (404).
  Future<AssistantInfo?> assistant() async {
    try {
      return AssistantInfo.fromJson((await _get('/api/assistant') as Map).cast<String, dynamic>());
    } on LoftError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// POST `/api/assistant`: send the assistant a message (starts it when it has no
  /// session yet). Returns its card id.
  Future<String> askAssistant(String message) async {
    final j = await _post('/api/assistant', {'message': message}, t: const Duration(seconds: 60)) as Map;
    return '${j['id'] ?? ''}';
  }

  /// POST `/api/assistant/reset`: archive the conversation; the next message starts fresh.
  Future<String> resetAssistant() async {
    final j = await _post('/api/assistant/reset', const {}, t: const Duration(seconds: 30));
    return j is Map ? '${j['message'] ?? ''}' : '';
  }

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

  /// POST `/api/files?name=`: store a file on the laptop; returns its absolute path
  /// there, for pointing an agent at it. A 404 means the laptop runs an older Loft.
  Future<String> upload(String name, List<int> bytes) async {
    try {
      final r = await _http
          .post(pairing.http(Uri(path: '/api/files', queryParameters: {'name': name}).toString()),
              headers: {...pairing.auth, 'Content-Type': 'application/octet-stream'}, body: bytes)
          .timeout(const Duration(seconds: 120));
      if (r.statusCode == 404) throw const LoftError('Update Loft on the laptop to send files.', status: 404);
      return '${(await _decode(r) as Map)['path']}';
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

  /// GET `/api/fs?path=<path>`: one folder's sub-folders (home when [path] is
  /// "~"). 404 = an older Loft without folder browsing; 403 = outside home.
  Future<FsListing> listDir(String path, {bool hidden = false}) async {
    final q = <String, String>{'path': path.isEmpty ? '~' : path, if (hidden) 'hidden': '1'};
    final j = await _get(Uri(path: '/api/fs', queryParameters: q).toString());
    return FsListing.fromJson((j as Map).cast<String, dynamic>());
  }

  /// GET `/api/sites`: each Loft account's signed-in browser and sites, and the
  /// agents that have a browser. 404 = an older Loft (no Sites browser).
  Future<SitesInfo> sites() async => SitesInfo.fromJson(await _get('/api/sites'));

  /// WebSocket for a live browser (`/ws/browser/<id>` or the Sites browser).
  /// Upgrades by hand so a refusal keeps its HTTP status (404 = this Loft
  /// doesn't share that browser with the phone).
  Future<WebSocket> browserSocket(String path) async {
    final hc = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final rnd = Random.secure();
      final req = await hc.openUrl('GET', pairing.http(path)).timeout(const Duration(seconds: 6));
      req.followRedirects = false;
      pairing.auth.forEach(req.headers.set);
      req.headers
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', base64.encode(List<int>.generate(16, (_) => rnd.nextInt(256))));
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != HttpStatus.switchingProtocols) {
        String body = '';
        try {
          body = await utf8.decodeStream(res).timeout(const Duration(seconds: 3));
        } catch (_) {}
        dynamic j;
        try {
          j = jsonDecode(body);
        } catch (_) {}
        final msg = j is Map ? '${j['message'] ?? j['error'] ?? 'Error ${res.statusCode}'}' : 'Error ${res.statusCode}';
        throw LoftError(msg, status: res.statusCode);
      }
      final socket = await res.detachSocket();
      final ws = WebSocket.fromUpgradedSocket(socket, serverSide: false);
      ws.pingInterval = const Duration(seconds: 20);
      return ws;
    } on LoftError {
      rethrow;
    } catch (e) {
      throw LoftError('Can\'t reach ${pairing.name}: ${_short(e)}');
    } finally {
      hc.close();
    }
  }

  void close() => _http.close();
}
