import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What the phone needs to reach Loft on the laptop.
class Pairing {
  final String host; // "100.119.140.39:7717"
  final String token; // device token (secret)
  final String name; // laptop name, e.g. "fedora"

  const Pairing({required this.host, required this.token, this.name = 'fedora'});

  Uri http(String path) => Uri.parse('http://$host$path');
  Uri ws(String path) => Uri.parse('ws://$host$path');
  Map<String, String> get auth => {'Authorization': 'Bearer $token'};

  /// Parses `loft://pair?h=<ip:port>&t=<token>&n=<name>` (the desktop QR).
  static Pairing? fromUri(String raw) {
    final u = Uri.tryParse(raw.trim());
    if (u == null || u.scheme != 'loft' || u.host != 'pair') return null;
    final h = u.queryParameters['h'] ?? '';
    final t = u.queryParameters['t'] ?? '';
    final host = normalizeHost(h);
    if (host == null || t.isEmpty) return null;
    return Pairing(host: host, token: t, name: (u.queryParameters['n'] ?? '').isEmpty ? 'fedora' : u.queryParameters['n']!);
  }

  /// "100.119.140.39" -> "100.119.140.39:7717"; rejects junk. Returns null if invalid.
  static String? normalizeHost(String raw) {
    var h = raw.trim().replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');
    if (h.isEmpty || h.contains(' ') || h.contains('/')) return null;
    if (!RegExp(r':\d{1,5}$').hasMatch(h)) h = '$h:7717';
    final port = int.parse(h.substring(h.lastIndexOf(':') + 1));
    if (port < 1 || port > 65535) return null;
    return h;
  }
}

class PairingStore {
  static const _s = FlutterSecureStorage();
  static const _kHost = 'loft.host', _kToken = 'loft.token', _kName = 'loft.name';

  static Future<Pairing?> load() async {
    try {
      final h = await _s.read(key: _kHost), t = await _s.read(key: _kToken), n = await _s.read(key: _kName);
      if (h == null || t == null) return null;
      return Pairing(host: h, token: t, name: n ?? 'fedora');
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(Pairing p) async {
    await _s.write(key: _kHost, value: p.host);
    await _s.write(key: _kToken, value: p.token);
    await _s.write(key: _kName, value: p.name);
  }

  static Future<void> clear() async {
    await _s.delete(key: _kHost);
    await _s.delete(key: _kToken);
    await _s.delete(key: _kName);
  }
}
