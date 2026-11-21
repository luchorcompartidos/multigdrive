import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'accounts.dart';
import 'evolution.dart';

/// Revisión diaria con la app cerrada (Android): cuotas de todas las cuentas y aviso.
class Background {
  static const _task = 'mgd-revision-diaria';
  static const enabledKey = 'mgd_bg_enabled';
  static const _lastKey = 'mgd_bg_last_alert';

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static final _notifications = FlutterLocalNotificationsPlugin();

  static Future<void> _initNotifications() async {
    await _notifications.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
  }

  /// Se llama al abrir la app: programa (o cancela) la revisión diaria.
  static Future<void> setup() async {
    if (!supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final on = prefs.getBool(enabledKey) ?? true;
      await Workmanager().initialize(callbackDispatcher);
      if (on) {
        await _initNotifications();
        await _notifications
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        await Workmanager().registerPeriodicTask(
          _task,
          _task,
          frequency: const Duration(hours: 24),
          initialDelay: const Duration(hours: 1),
          constraints: Constraints(networkType: NetworkType.connected),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        );
      } else {
        await Workmanager().cancelByUniqueName(_task);
      }
    } catch (_) {}
  }

  static Future<void> setEnabled(bool on) async {
    await (await SharedPreferences.getInstance()).setBool(enabledKey, on);
    await setup();
  }

  /// Trabajo en segundo plano: actualiza cuotas y avisa si alguna cuenta supera el %.
  static Future<bool> run() async {
    final store = AccountStore();
    await store.load();
    final over = <Account>[];
    for (final a in store.accounts) {
      await store.refreshQuota(a);
      if (store.overAlert(a)) over.add(a);
    }
    await Usage.record(store.accounts);
    if (over.isEmpty) return true;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_lastKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < const Duration(hours: 20).inMilliseconds) return true;
    await prefs.setInt(_lastKey, now);
    await _initNotifications();
    final body = over
        .map((a) => '${a.title}: ${(a.quota!.ratio! * 100).round()} % (libre ${formatBytes(a.quota!.free)})')
        .join('\n');
    await _notifications.show(
      1,
      over.length == 1 ? 'Una cuenta está casi llena' : '${over.length} cuentas están casi llenas',
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'cuotas',
          'Cuotas de almacenamiento',
          channelDescription: 'Aviso diario cuando una cuenta supera el % configurado',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(body),
        ),
      ),
    );
    return true;
  }
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      return await Background.run();
    } catch (_) {
      return false;
    }
  });
}
