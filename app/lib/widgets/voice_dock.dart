import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/tokens.dart';
import '../voice/trailing_command.dart';
import '../voice/voice_controller.dart';
import 'common.dart';

/// Appends a transcript to [field]; if it ends with "send it" / "start it",
/// strips the phrase and fires [go] after a 2 s Undo window.
/// Returns a cancel function (also wired to the snackbar's Undo).
void deliverTranscript(BuildContext context, TextEditingController field, String transcript, {required VoidCallback go, required String goLabel}) {
  if (transcript.trim().isEmpty) return;
  final t = parseTrailing(transcript);
  final before = field.text.trimRight();
  field.text = before.isEmpty ? t.text : '$before ${t.text}';
  field.selection = TextSelection.collapsed(offset: field.text.length);
  if (!t.go || field.text.trim().isEmpty) return;
  var undone = false;
  final timer = Timer(const Duration(seconds: 2), () {
    if (!undone) go();
  });
  toast(context, '$goLabel…',
      duration: const Duration(seconds: 2),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          undone = true;
          timer.cancel();
        },
      ));
}

/// The mic button: tap = keep listening (tap again to stop); hold = talk,
/// release = stop; slide left while holding = cancel. Haptic tick on start/stop.
class MicButton extends StatefulWidget {
  final VoiceController voice;
  final double size;
  final Future<void> Function(String text) onDone;
  const MicButton({super.key, required this.voice, required this.onDone, this.size = 72});
  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton> {
  bool _holding = false;

  Future<void> _finish() async {
    final text = await widget.voice.stop();
    await widget.onDone(text);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.voice;
    final s = widget.size;
    final icon = s >= 90 ? 36.0 : (s >= 60 ? 28.0 : 22.0);
    if (v.phase == VoicePhase.transcribing) {
      return Container(
        width: s,
        height: s,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: C.raised),
        alignment: Alignment.center,
        child: SizedBox(width: icon - 4, height: icon - 4, child: const CircularProgressIndicator(strokeWidth: 2.4, color: C.t2)),
      );
    }
    final listening = v.listening;
    return Semantics(
      button: true,
      label: listening ? 'Stop listening' : 'Speak. Tap to keep listening, or hold to talk.',
      child: GestureDetector(
        onTap: () async {
          if (listening) {
            await _finish();
          } else {
            await v.start();
          }
        },
        onLongPressStart: (_) async {
          if (listening) return;
          _holding = true;
          await v.start();
        },
        onLongPressMoveUpdate: (d) {
          if (_holding && d.offsetFromOrigin.dx < -80) {
            _holding = false;
            v.cancel();
          }
        },
        onLongPressEnd: (_) async {
          if (!_holding) return;
          _holding = false;
          if (v.listening) await _finish();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: s,
          height: s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: C.primary,
            border: listening ? Border.all(color: C.failed, width: 4) : null,
          ),
          alignment: Alignment.center,
          child: Icon(listening ? LucideIcons.square : LucideIcons.mic, size: listening ? icon - 6 : icon, color: C.onPrimary),
        ),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final bool filled;
  final bool outlined;
  const _RoundBtn(this.icon, {required this.onTap, required this.tooltip, this.filled = false, this.outlined = false});
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: filled && onTap != null ? C.primary : (outlined ? Colors.transparent : C.raised),
          shape: CircleBorder(side: outlined ? const BorderSide(color: C.borderStrong) : BorderSide.none),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(icon, size: 22, color: onTap == null ? C.t3 : (filled ? C.onPrimary : C.t1)),
            ),
          ),
        ),
      );
}

/// Figma "Voice dock": Idle / Listening / Transcribing / Ready / Phone speech.
class VoiceDock extends StatelessWidget {
  final VoiceController voice;
  final TextEditingController field;
  final FocusNode focus;
  final String placeholder;
  final String hostName;
  final bool laptopReachable;
  final VoidCallback onSend;
  final Future<void> Function(String) onTranscript;
  /// One row (field, mic, send) for the chat view; the hint only shows while it matters.
  final bool compact;
  /// A line above the field, e.g. 'Other answer for "Pick toppings"' (amber), with Cancel.
  final String? chip;
  final VoidCallback? onChipCancel;
  /// A note above the field, e.g. replies queued while offline (amber).
  final String? banner;
  /// Paperclip: pick files on the phone and add their laptop paths to the field.
  final VoidCallback? onAttach;

  const VoiceDock({
    super.key,
    required this.voice,
    required this.field,
    required this.focus,
    required this.onSend,
    required this.onTranscript,
    this.placeholder = 'Reply, or hold the mic',
    this.hostName = 'fedora',
    this.laptopReachable = true,
    this.compact = false,
    this.chip,
    this.onChipCancel,
    this.banner,
    this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([voice, field]),
      builder: (context, _) {
        final listening = voice.listening, transcribing = voice.phase == VoicePhase.transcribing;
        final hasText = field.text.trim().isNotEmpty;
        final phone = voice.phoneSpeech || !laptopReachable;

        Widget box;
        if (listening || transcribing) {
          final live = voice.live;
          box = Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: S.s4, vertical: S.s3),
            decoration: BoxDecoration(color: C.raised, border: Border.all(color: C.borderStrong), borderRadius: BorderRadius.circular(R.md)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (listening) ...[
                Row(children: [
                  const Dot(C.failed),
                  const SizedBox(width: S.s2),
                  const Text('Listening', style: TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: C.t1)),
                  const SizedBox(width: S.s2),
                  Text(clock(voice.elapsed), style: T.mono13),
                  const SizedBox(width: S.s2),
                  Flexible(child: ClipRect(child: LevelBars(voice.levels.sublist(4)))),
                ]),
                const SizedBox(height: S.s2),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text.rich(
                    TextSpan(children: [
                      if (field.text.trim().isNotEmpty) TextSpan(text: '${field.text.trim()} '),
                      TextSpan(text: live.stable),
                      if (live.tail.isNotEmpty) TextSpan(text: '${live.stable.isEmpty ? '' : ' '}${live.tail}', style: const TextStyle(color: C.t3)),
                      if (live.stable.isEmpty && live.tail.isEmpty && field.text.trim().isEmpty)
                        TextSpan(text: listening ? 'Say it…' : '', style: const TextStyle(color: C.t3)),
                    ]),
                    style: const TextStyle(fontFamily: F.sans, fontSize: 16, height: 22 / 16, color: C.t1),
                  ),
                ),
              ),
            ]),
          );
        } else {
          box = TextField(
            controller: field,
            focusNode: focus,
            minLines: 1,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontFamily: F.sans, fontSize: 16, height: 22 / 16, color: C.t1),
            decoration: InputDecoration(
              hintText: placeholder,
              hintStyle: const TextStyle(fontFamily: F.sans, fontSize: 16, color: C.t3),
              filled: true,
              fillColor: C.raised,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: S.s4, vertical: 13),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.borderStrong)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.t3)),
            ),
          );
        }

        final String hint;
        Widget hintW;
        if (transcribing) {
          hintW = Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: C.t2)),
            const SizedBox(width: 6),
            Text(voice.phoneSpeech ? 'Finishing on the phone' : 'Transcribing on $hostName', style: const TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: C.t1)),
          ]);
        } else if (voice.error != null && !listening) {
          hintW = Text(voice.error!, textAlign: TextAlign.center, style: T.caption.copyWith(color: C.failed));
        } else if (phone) {
          hintW = Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(LucideIcons.wifiOff, size: 14, color: C.needs),
            const SizedBox(width: 6),
            Flexible(child: Text('Phone speech · $hostName unreachable, check names', overflow: TextOverflow.ellipsis, style: T.caption.copyWith(color: C.needs, fontWeight: FontWeight.w500))),
          ]);
        } else {
          hint = listening
              ? 'Release or tap to stop · slide left to cancel · say "send it"'
              : hasText
                  ? 'Tap send, or end with "send it" next time'
                  : 'Hold to talk · tap to keep listening';
          hintW = Text(hint, textAlign: TextAlign.center, style: T.caption);
        }

        if (compact) {
          final showHint = listening || transcribing || voice.error != null || phone;
          return Container(
            decoration: const BoxDecoration(color: C.surface, border: Border(top: BorderSide(color: C.border))),
            padding: const EdgeInsets.fromLTRB(S.s4, 10, S.s3, S.s2),
            child: SafeArea(
              top: false,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (chip != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: S.s2),
                    child: Row(children: [
                      const Icon(LucideIcons.pencilLine, size: 14, color: C.needs),
                      const SizedBox(width: 6),
                      Expanded(child: Text(chip!, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.caption.copyWith(color: C.needs, fontWeight: FontWeight.w500))),
                      if (onChipCancel != null)
                        InkWell(
                          onTap: onChipCancel,
                          child: const Padding(padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: Text('Cancel', style: TextStyle(fontFamily: F.sans, fontSize: 12, fontWeight: FontWeight.w500, color: C.t2))),
                        ),
                    ]),
                  ),
                if (banner != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: S.s2),
                    child: Row(children: [
                      const Icon(LucideIcons.wifiOff, size: 14, color: C.needs),
                      const SizedBox(width: 6),
                      Expanded(child: Text(banner!, style: T.caption.copyWith(color: C.needs, fontWeight: FontWeight.w500))),
                    ]),
                  ),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (onAttach != null) ...[
                    _RoundBtn(LucideIcons.paperclip, tooltip: 'Attach', onTap: listening || transcribing ? null : onAttach),
                    const SizedBox(width: S.s2),
                  ],
                  Expanded(child: box),
                  const SizedBox(width: S.s2),
                  MicButton(voice: voice, size: 48, onDone: onTranscript),
                  const SizedBox(width: S.s2),
                  _RoundBtn(LucideIcons.arrowUp, tooltip: 'Send', filled: true, outlined: !(hasText && !listening && !transcribing), onTap: hasText && !listening && !transcribing ? onSend : null),
                ]),
                if (showHint) ...[const SizedBox(height: S.s2), SizedBox(height: 18, child: Center(child: hintW))],
              ]),
            ),
          );
        }

        return Container(
          decoration: const BoxDecoration(color: C.surface, border: Border(top: BorderSide(color: C.border))),
          padding: const EdgeInsets.fromLTRB(S.s4, S.s3, S.s4, S.s2),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              box,
              const SizedBox(height: S.s3),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (onAttach != null) ...[
                  _RoundBtn(LucideIcons.paperclip, tooltip: 'Attach', outlined: true, onTap: listening || transcribing ? null : onAttach),
                  const SizedBox(width: S.s4),
                ],
                if (listening || transcribing)
                  _RoundBtn(LucideIcons.x, tooltip: 'Cancel', outlined: true, onTap: transcribing ? null : voice.cancel)
                else
                  _RoundBtn(LucideIcons.keyboard, tooltip: 'Type', outlined: true, onTap: () => focus.requestFocus()),
                const SizedBox(width: S.s8),
                MicButton(voice: voice, onDone: onTranscript),
                const SizedBox(width: S.s8),
                _RoundBtn(LucideIcons.arrowUp, tooltip: 'Send', filled: true, onTap: hasText && !listening && !transcribing ? onSend : null),
              ]),
              const SizedBox(height: S.s3),
              SizedBox(height: 18, child: Center(child: hintW)),
            ]),
          ),
        );
      },
    );
  }
}
