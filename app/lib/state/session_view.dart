import 'package:flutter_riverpod/flutter_riverpod.dart';

enum SessionView { chat, terminal }

/// The laptop's Loft has no chat API (an older build): skip Chat until the app restarts.
final chatUnsupportedProvider = StateProvider<bool>((ref) => false);
