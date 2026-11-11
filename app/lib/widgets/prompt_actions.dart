import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat.dart';
import '../data/loft_client.dart';
import '../state/conn.dart';
import 'common.dart';

/// Answering a picker from the phone (chat and It's-asking screens): a short
/// Undo window, then POST /answer; 409 = the question changed, reload.
mixin PromptActions<W extends ConsumerStatefulWidget> on ConsumerState<W> {
  bool answering = false;

  /// Called after an answer went through, or the question changed.
  Future<void> reloadPrompt();

  static const undoFor = Duration(seconds: 2);

  /// Shows [msg] with Undo; true when the window passed without Undo.
  Future<bool> undoWindow(String msg) {
    final done = Completer<bool>();
    toast(context, msg,
        duration: undoFor + const Duration(milliseconds: 400),
        action: SnackBarAction(label: 'Undo', onPressed: () {
          if (!done.isCompleted) done.complete(false);
        }));
    Timer(undoFor, () {
      if (!done.isCompleted) done.complete(true);
    });
    return done.future;
  }

  bool _canAnswer() {
    if (ref.read(connProvider).online) return true;
    toast(context, 'Can\'t answer while ${ref.read(pairingProvider)?.name ?? 'the laptop'} is offline. Try again when it\'s back.', error: true);
    return false;
  }

  Future<void> answerQuestion(String cardId, PickerState s) async {
    if (answering || !_canAnswer()) return;
    setState(() => answering = true);
    try {
      if (!await undoWindow('Answering “${s.summary()}”…')) return;
      await _post(() => ref.read(clientProvider)!.answer(cardId, tool: s.prompt.tool, answers: s.answers()));
    } finally {
      if (mounted) setState(() => answering = false);
    }
  }

  Future<void> answerPermission(String cardId, PendingPrompt p, int n, String label, {String? thenReply}) async {
    if (answering || !_canAnswer()) return;
    setState(() => answering = true);
    try {
      if (!await undoWindow(thenReply == null ? 'Answering “$label”…' : 'Answering “$label”, then sending your reply…')) return;
      final ok = await _post(() => ref.read(clientProvider)!.answer(cardId, tool: p.tool, permission: n));
      if (ok && thenReply != null) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await ref.read(clientProvider)!.reply(cardId, thenReply);
        if (mounted) toast(context, 'Sent');
      }
    } on LoftError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => answering = false);
    }
  }

  Future<bool> _post(Future<String> Function() send) async {
    try {
      final m = await send();
      if (mounted) toast(context, m == 'Answered' ? 'Answered' : 'Sent. It should carry on in a moment.');
      await reloadPrompt();
      return true;
    } on LoftError catch (e) {
      if (!mounted) return false;
      if (e.status == 409) {
        toast(context, 'The question changed. Here is the current one.', error: true);
        await reloadPrompt();
      } else if (e.status == 404) {
        toast(context, 'This Loft can\'t answer pickers yet. Use Terminal.', error: true);
      } else {
        toast(context, e.message, error: true);
      }
      return false;
    }
  }
}
