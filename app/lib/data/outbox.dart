import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'loft_client.dart';

/// Sends made while the laptop is unreachable wait here and go out, in order,
/// once it is back ("sends wait", Figma Inbox · Offline).
class OutboxItem {
  final String kind; // reply | create
  final Map<String, dynamic> data;
  final DateTime at;
  OutboxItem(this.kind, this.data, [DateTime? at]) : at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {'kind': kind, 'data': data, 'at': at.toIso8601String()};
  factory OutboxItem.fromJson(Map<String, dynamic> j) =>
      OutboxItem('${j['kind']}', (j['data'] as Map).cast<String, dynamic>(), DateTime.tryParse('${j['at']}'));

  String get label => kind == 'reply' ? 'Reply: ${data['text']}' : 'New task: ${data['prompt']}';
}

class Outbox {
  static const _key = 'loft.outbox';
  final List<OutboxItem> items;
  Outbox(this.items);

  static Future<Outbox> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null) return Outbox([]);
      return Outbox([for (final e in jsonDecode(raw) as List) OutboxItem.fromJson((e as Map).cast<String, dynamic>())]);
    } catch (_) {
      return Outbox([]);
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode([for (final i in items) i.toJson()]));
  }

  Future<void> add(OutboxItem i) async {
    items.add(i);
    await save();
  }

  /// Sends what it can. Stops at the first network failure (still offline);
  /// drops items the server rejects (e.g. the agent was archived), returning their errors.
  Future<({int sent, List<String> errors})> flush(LoftClient c) async {
    var sent = 0;
    final errors = <String>[];
    while (items.isNotEmpty) {
      final i = items.first;
      try {
        if (i.kind == 'reply') {
          await c.reply('${i.data['id']}', '${i.data['text']}');
        } else {
          await c.create(prompt: '${i.data['prompt']}', account: '${i.data['account']}', cwd: '${i.data['cwd']}', start: i.data['start'] == true);
        }
        sent++;
      } on LoftError catch (e) {
        if (e.offline) break;
        errors.add('${i.label}: ${e.message}');
      }
      items.removeAt(0);
      await save();
    }
    return (sent: sent, errors: errors);
  }
}
