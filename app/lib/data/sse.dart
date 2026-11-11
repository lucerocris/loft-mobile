/// A small Server-Sent Events parser. Hand-written because the phone has to
/// send `Authorization: Bearer`, which most SSE packages can't.
library;

import 'dart:async';
import 'dart:convert';

class SseEvent {
  final String event;
  final String data;
  const SseEvent(this.data, {this.event = 'message'});
  @override
  String toString() => 'SseEvent($event, ${data.length} chars)';
}

/// Feed it decoded text in any chunking; it emits whole events.
/// Comment lines (": ping") are reported through [onComment] so the caller
/// can treat them as a heartbeat.
class SseParser {
  final void Function(SseEvent) onEvent;
  final void Function(String)? onComment;
  final _line = StringBuffer();
  final _data = <String>[];
  String _event = 'message';
  bool _lastWasCr = false;

  SseParser({required this.onEvent, this.onComment});

  void add(String chunk) {
    for (var i = 0; i < chunk.length; i++) {
      final ch = chunk[i];
      if (ch == '\n' && _lastWasCr) {
        _lastWasCr = false;
        continue;
      }
      _lastWasCr = ch == '\r';
      if (ch == '\n' || ch == '\r') {
        _endLine(_line.toString());
        _line.clear();
      } else {
        _line.write(ch);
      }
    }
  }

  void _endLine(String line) {
    if (line.isEmpty) {
      if (_data.isNotEmpty) onEvent(SseEvent(_data.join('\n'), event: _event));
      _data.clear();
      _event = 'message';
      return;
    }
    if (line.startsWith(':')) {
      onComment?.call(line.substring(1).trim());
      return;
    }
    final i = line.indexOf(':');
    final field = i < 0 ? line : line.substring(0, i);
    var value = i < 0 ? '' : line.substring(i + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        _data.add(value);
      case 'event':
        _event = value;
    }
  }
}

/// Turns a byte stream into SSE events (null = heartbeat comment).
Stream<SseEvent?> sseEvents(Stream<List<int>> bytes) {
  final out = StreamController<SseEvent?>();
  final parser = SseParser(onEvent: out.add, onComment: (_) => out.add(null));
  final sub = bytes.transform(const Utf8Decoder(allowMalformed: true)).listen(parser.add, onError: out.addError, onDone: out.close);
  out.onCancel = sub.cancel;
  return out.stream;
}
