import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SessionView { chat, terminal }

/// Chat or Terminal when an agent opens. Remembered on the phone (main() loads it).
final sessionViewProvider = StateProvider<SessionView>((ref) => SessionView.chat);

/// The laptop's Loft has no chat API (an older build): skip Chat until the app restarts.
final chatUnsupportedProvider = StateProvider<bool>((ref) => false);

const _key = 'loft.sessionView';

Future<SessionView> loadSessionView() async {
  try {
    final p = await SharedPreferences.getInstance();
    return p.getString(_key) == 'terminal' ? SessionView.terminal : SessionView.chat;
  } catch (_) {
    return SessionView.chat;
  }
}

Future<void> saveSessionView(WidgetRef ref, SessionView v) async {
  ref.read(sessionViewProvider.notifier).state = v;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, v.name);
  } catch (_) {}
}
