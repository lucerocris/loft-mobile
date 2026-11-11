import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/loft_client.dart';
import '../data/models.dart';
import '../data/pairing.dart';

/// "Needs you" alerts without any outside push service: an Android foreground
/// service keeps one SSE connection to the laptop open over Tailscale and
/// posts a local notification when an agent starts waiting. Toggle in the
/// menu ("Needs-you alerts"); it costs a permanent notification and some battery.
abstract final class Alerts {
  static const prefKey = 'loft.alerts';
  static const channelId = 'loft_needs';
  static final notifications = FlutterLocalNotificationsPlugin();

  /// Set by the app to open an agent when a notification is tapped.
  static void Function(String cardId)? onOpen;

  static Future<void> initNotifications({bool foreground = true}) async {
    await notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_loft'),
        // Alerts are Android-only for now; don't prompt for notification permission on iOS launch.
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
      ),
      onDidReceiveNotificationResponse: foreground ? (r) => _open(r.payload) : null,
    );
    await notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(channelId, 'Agents that need you',
            description: 'When a background agent stops and asks you something', importance: Importance.high));
  }

  static void _open(String? payload) {
    if (payload != null && payload.isNotEmpty) onOpen?.call(payload);
  }

  /// Card id from the notification that launched the app, if any.
  static Future<String?> launchPayload() async {
    final d = await notifications.getNotificationAppLaunchDetails();
    return (d?.didNotificationLaunchApp ?? false) ? d!.notificationResponse?.payload : null;
  }

  static void initService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'loft_watch',
        channelName: 'Loft connection',
        channelDescription: 'Keeps Loft connected to the laptop so it can tell you when an agent needs you',
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<bool> enabled() async => (await SharedPreferences.getInstance()).getBool(prefKey) ?? false;

  /// Turns alerts on or off. Returns an error message, or null when it worked.
  static Future<String?> setEnabled(bool on) async {
    final p = await SharedPreferences.getInstance();
    if (!on) {
      await p.setBool(prefKey, false);
      if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
      return null;
    }
    if (!Platform.isAndroid) return 'Alerts need Android for now.';
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted && await FlutterForegroundTask.requestNotificationPermission() != NotificationPermission.granted) {
      return 'Allow notifications for Loft first.';
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    await p.setBool(prefKey, true);
    return start();
  }

  static Future<String?> start() async {
    initService();
    final r = await (await FlutterForegroundTask.isRunningService
        ? FlutterForegroundTask.restartService()
        : FlutterForegroundTask.startService(
            serviceId: 7717,
            serviceTypes: [ForegroundServiceTypes.remoteMessaging],
            notificationTitle: 'Loft is watching your agents',
            notificationText: 'Connecting…',
            notificationIcon: const NotificationIcon(metaDataName: 'dev.xaria.loft.STAT_ICON'),
            callback: startWatcher,
          ));
    return r is ServiceRequestFailure ? '${r.error}' : null;
  }
}

@pragma('vm:entry-point')
void startWatcher() => FlutterForegroundTask.setTaskHandler(NeedsWatcher());

/// Runs in the foreground service's isolate.
class NeedsWatcher extends TaskHandler {
  LoftClient? _client;
  StreamSubscription<Snapshot?>? _sub;
  Set<String>? _known;
  Timer? _retry;
  bool _stopped = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await Alerts.initNotifications(foreground: false);
    final p = await PairingStore.load();
    if (p == null) {
      FlutterForegroundTask.updateService(notificationText: 'Not paired');
      return;
    }
    _client = LoftClient(p);
    _connect();
  }

  void _connect() {
    if (_stopped || _client == null) return;
    _sub?.cancel();
    _sub = _client!.events().listen((snap) {
      if (snap == null) return;
      _seen(snap);
    }, onError: (Object e) => _down(e is LoftError && e.unauthorized ? 'Unpaired on the laptop' : 'Can\'t reach ${_client!.pairing.name}'),
        onDone: () => _down('Reconnecting…'), cancelOnError: true);
  }

  void _down(String why) {
    FlutterForegroundTask.updateService(notificationText: why);
    _retry?.cancel();
    if (!why.startsWith('Unpaired')) _retry = Timer(const Duration(seconds: 15), _connect);
  }

  Future<void> _seen(Snapshot snap) async {
    final needs = snap.cards.where((c) => c.col == Col.needs).toList();
    final n = needs.length;
    FlutterForegroundTask.updateService(notificationText: n == 0 ? 'Nothing needs you · ${_client!.pairing.name}' : '$n ${n == 1 ? 'agent needs' : 'agents need'} you');
    final known = _known;
    _known = {for (final c in needs) c.id};
    if (known == null) return; // first snapshot: don't alert for what was already waiting
    for (final c in needs.where((c) => !known.contains(c.id))) {
      await Alerts.notifications.show(
        id: c.id.hashCode & 0x7fffffff,
        title: [if (snap.multiAccount) snap.accountLabel(c.account), ?snap.projectOf(c)?.name, c.name].join(' · '),
        body: c.detail.isEmpty ? 'Needs you' : c.detail,
        payload: c.id,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(Alerts.channelId, 'Agents that need you',
              importance: Importance.high, priority: Priority.high, category: AndroidNotificationCategory.message, icon: '@drawable/ic_stat_loft'),
        ),
      );
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_sub == null && !_stopped) _connect();
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _stopped = true;
    _retry?.cancel();
    await _sub?.cancel();
    _client?.close();
    if (kDebugMode) debugPrint('Loft watcher stopped (timeout: $isTimeout)');
  }
}
