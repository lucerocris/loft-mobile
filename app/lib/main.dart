import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/pairing.dart';
import 'notify/watcher.dart';
import 'state/conn.dart';
import 'state/session_view.dart';
import 'theme/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: C.canvas,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  final pairing = await PairingStore.load();
  final view = await loadSessionView();
  String? openCard;
  try {
    await Alerts.initNotifications();
    openCard = await Alerts.launchPayload();
    if (pairing != null && await Alerts.enabled()) {
      await Alerts.start(); // resume the needs-you watcher if it was on
    }
  } catch (_) {}
  runApp(ProviderScope(
    overrides: [pairingProvider.overrideWith((ref) => pairing), sessionViewProvider.overrideWith((ref) => view)],
    child: LoftApp(openCard: pairing == null ? null : openCard),
  ));
}
