import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/loft_client.dart';
import 'conn.dart';

/// Does the laptop's Loft have the Loft Assistant? true = yes (show the entry),
/// false = GET /api/assistant 404s (an older Loft: hide it), null = not known yet.
/// Checked whenever the laptop comes online; a snapshot with an assistant card
/// also counts as yes.
class AssistantSupport extends StateNotifier<bool?> {
  final LoftClient? client;
  bool _checking = false;
  AssistantSupport(this.client) : super(null);

  Future<void> check() async {
    final c = client;
    if (c == null || _checking || !mounted) return;
    _checking = true;
    try {
      final info = await c.assistant();
      if (mounted) state = info != null;
    } on LoftError catch (_) {
      // Offline or a server error: keep what we knew.
    } finally {
      _checking = false;
    }
  }

  void seen() {
    if (mounted && state != true) state = true;
  }
}

final assistantSupportProvider = StateNotifierProvider<AssistantSupport, bool?>((ref) {
  final n = AssistantSupport(ref.watch(clientProvider));
  ref.listen<bool>(connProvider.select((c) => c.online), (was, now) {
    if (now && was != true) n.check();
  }, fireImmediately: true);
  ref.listen<bool>(connProvider.select((c) => c.snap.assistant != null), (_, has) {
    if (has) n.seen();
  }, fireImmediately: true);
  return n;
});
