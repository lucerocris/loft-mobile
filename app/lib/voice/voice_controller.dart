import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/loft_client.dart';
import 'trailing_command.dart';

enum VoicePhase { idle, listening, transcribing }

/// Debug-only test input: with `--dart-define=LOFT_FAKE_MIC=true` (debug
/// builds only) the "mic" streams PCM16 16 kHz mono from
/// the app's files dir (fake_mic.pcm, pushed with `adb shell run-as`) instead of the real
/// microphone, so the live-words path can be checked on an emulator.
const _fakeMicFlag = bool.fromEnvironment('LOFT_FAKE_MIC');
const fakeMicPath = '/data/user/0/dev.xaria.loft/files/fake_mic.pcm';

/// Records and transcribes. Default: streams PCM16 to the laptop's Whisper
/// over /ws/voice and shows its partial text live. When the laptop can't be
/// reached it falls back to Android's on-device speech (the "Phone speech"
/// dock state); then brand names may be wrong, so the text stays editable.
class VoiceController extends ChangeNotifier {
  final LoftClient? Function() client;
  final bool Function() laptopReachable;

  VoiceController({required this.client, required this.laptopReachable});

  VoicePhase phase = VoicePhase.idle;
  String text = ''; // live partial while listening, final after
  String previous = ''; // the partial before, for the grey "unsettled" tail
  bool phoneSpeech = false; // this take used on-device speech
  String? error;
  final List<double> levels = List<double>.filled(20, 0.0, growable: true);
  Duration elapsed = Duration.zero;

  AudioRecorder? _recorder; // created on first use
  AudioRecorder get _rec => _recorder ??= AudioRecorder();
  final _stt = SpeechToText();
  bool _sttReady = false;
  WebSocketChannel? _ws;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription<Amplitude>? _ampSub;
  StreamSubscription? _wsSub;
  Completer<String>? _final;
  Timer? _clock, _fakeTimer;
  DateTime? _startedAt;
  bool _disposed = false;

  bool get listening => phase == VoicePhase.listening;
  bool get busy => phase != VoicePhase.idle;

  void _set(VoidCallback f) {
    if (_disposed) return;
    f();
    notifyListeners();
  }

  void _pushLevel(double v) {
    levels.removeAt(0);
    levels.add(v.clamp(0.0, 1.0));
  }

  /// Starts listening. Returns false (with [error] set) if it couldn't.
  Future<bool> start() async {
    if (busy) return true;
    error = null;
    text = '';
    previous = '';
    levels.fillRange(0, levels.length, 0);
    final useFake = kDebugMode && _fakeMicFlag;
    if (!useFake && !await _rec.hasPermission()) {
      _set(() => error = 'Loft needs the microphone. Allow it in Android settings.');
      return false;
    }
    HapticFeedback.selectionClick();
    final c = client();
    if (c != null && laptopReachable()) {
      try {
        _ws = await c.voice().timeout(const Duration(seconds: 4));
        phoneSpeech = false;
      } catch (_) {
        _ws = null;
      }
    }
    if (_ws == null) return _startPhoneSpeech();
    _final = Completer<String>();
    _wsSub = _ws!.stream.listen((m) {
      if (m is! String) return;
      final j = jsonDecode(m) as Map;
      switch (j['type']) {
        case 'partial':
          _set(() {
            previous = text;
            text = '${j['text'] ?? ''}';
          });
        case 'final':
          if (!(_final?.isCompleted ?? true)) _final!.complete('${j['text'] ?? ''}');
        case 'error':
          _set(() => error = '${j['message']}');
      }
    }, onDone: () {
      if (!(_final?.isCompleted ?? true)) _final!.complete(text);
    }, onError: (_) {
      if (!(_final?.isCompleted ?? true)) _final!.complete(text);
    });
    try {
      if (useFake) {
        _startFakeMic();
      } else {
        final stream = await _rec.startStream(const RecordConfig(
            encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1, noiseSuppress: true, autoGain: true, echoCancel: true));
        _audioSub = stream.listen((b) => _ws?.sink.add(b));
        _ampSub = _rec.onAmplitudeChanged(const Duration(milliseconds: 90)).listen((a) => _set(() => _pushLevel((a.current + 50) / 45)));
      }
    } catch (e) {
      await _closeWs(cancel: true);
      _set(() => error = 'Couldn\'t start the microphone: $e');
      return false;
    }
    _startClock();
    _set(() => phase = VoicePhase.listening);
    return true;
  }

  void _startFakeMic() {
    final f = File(fakeMicPath);
    final pcm = f.existsSync() ? f.readAsBytesSync() : Uint8List(0);
    debugPrint('Loft fake mic: ${pcm.length} bytes from $fakeMicPath');
    var i = 0;
    _fakeTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (i >= pcm.length) {
        _set(() => _pushLevel(0));
        return;
      }
      final chunk = pcm.sublist(i, (i + 3200).clamp(0, pcm.length));
      i += 3200;
      _ws?.sink.add(chunk);
      var peak = 0;
      for (var k = 0; k + 1 < chunk.length; k += 2) {
        final v = (chunk[k] | (chunk[k + 1] << 8)).toSigned(16).abs();
        if (v > peak) peak = v;
      }
      _set(() => _pushLevel(peak / 20000));
    });
  }

  Future<bool> _startPhoneSpeech() async {
    phoneSpeech = true;
    try {
      _sttReady = _sttReady || await _stt.initialize(onError: (e) => _set(() => error = e.errorMsg));
    } catch (_) {
      _sttReady = false;
    }
    if (!_sttReady) {
      _set(() => error = '${client()?.pairing.name ?? 'The laptop'} is unreachable and phone speech isn\'t available.');
      return false;
    }
    _final = Completer<String>();
    await _stt.listen(
      onResult: (r) {
        _set(() {
          previous = text;
          text = r.recognizedWords;
        });
        if (r.finalResult && !(_final?.isCompleted ?? true)) _final!.complete(r.recognizedWords);
      },
      onSoundLevelChange: (l) => _set(() => _pushLevel((l + 2) / 12)),
      listenOptions: SpeechListenOptions(listenFor: const Duration(minutes: 3), pauseFor: const Duration(seconds: 8), partialResults: true, listenMode: ListenMode.dictation, cancelOnError: true),
    );
    _startClock();
    _set(() => phase = VoicePhase.listening);
    return true;
  }

  void _startClock() {
    _startedAt = DateTime.now();
    elapsed = Duration.zero;
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(milliseconds: 250), (_) => _set(() => elapsed = DateTime.now().difference(_startedAt!)));
  }

  /// Stops and returns the final transcript ('' if nothing was heard).
  Future<String> stop() async {
    if (phase != VoicePhase.listening) return text;
    HapticFeedback.selectionClick();
    _clock?.cancel();
    _set(() => phase = VoicePhase.transcribing);
    String out;
    if (phoneSpeech) {
      await _stt.stop();
      out = await (_final?.future ?? Future.value(text)).timeout(const Duration(seconds: 3), onTimeout: () => text);
    } else {
      _fakeTimer?.cancel();
      await _audioSub?.cancel();
      await _ampSub?.cancel();
      try {
        await _rec.stop();
      } catch (_) {}
      _ws?.sink.add(jsonEncode({'type': 'stop'}));
      out = await (_final?.future ?? Future.value(text)).timeout(const Duration(seconds: 25), onTimeout: () => text);
      await _closeWs();
    }
    _set(() {
      text = out.trim();
      previous = text;
      phase = VoicePhase.idle;
    });
    return text;
  }

  Future<void> cancel() async {
    if (!busy) return;
    HapticFeedback.lightImpact();
    _clock?.cancel();
    _fakeTimer?.cancel();
    if (phoneSpeech) {
      await _stt.cancel();
    } else {
      await _audioSub?.cancel();
      await _ampSub?.cancel();
      try {
        await _rec.cancel();
      } catch (_) {}
      await _closeWs(cancel: true);
    }
    _set(() {
      text = '';
      previous = '';
      phase = VoicePhase.idle;
    });
  }

  Future<void> _closeWs({bool cancel = false}) async {
    final ws = _ws;
    _ws = null;
    if (ws == null) return;
    if (cancel) {
      try {
        ws.sink.add(jsonEncode({'type': 'cancel'}));
      } catch (_) {}
    }
    await _wsSub?.cancel();
    try {
      await ws.sink.close();
    } catch (_) {}
  }

  /// The live text split into settled words and the grey unsettled tail.
  ({String stable, String tail}) get live => listening ? splitPartial(previous, text) : (stable: text, tail: '');

  @override
  void dispose() {
    _disposed = true;
    _clock?.cancel();
    _fakeTimer?.cancel();
    _audioSub?.cancel();
    _ampSub?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close();
    _recorder?.dispose();
    if (phoneSpeech) _stt.cancel();
    super.dispose();
  }
}
