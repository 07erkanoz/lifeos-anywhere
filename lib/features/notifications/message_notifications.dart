import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:anyware/core/app_visibility.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/platform/windows/notification_service.dart';

final _log = AppLogger('MessageNotifications');

/// Notifications for incoming İleti messages and files, while the app is not
/// on screen. On Android a channel for each sound/vibration choice: a
/// channel's sound and vibration cannot change once made, so the setting
/// picks the channel.
class MessageNotifications {
  MessageNotifications._();
  static final MessageNotifications instance = MessageNotifications._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// A notification was tapped: the device whose conversation to open.
  final ValueNotifier<String?> opened = ValueNotifier(null);

  Future<void> init() async {
    if (_ready || !Platform.isAndroid) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (r) {
          final device = r.payload;
          if (device != null && device.isNotEmpty) opened.value = device;
        },
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final payload = launch?.notificationResponse?.payload;
      if ((launch?.didNotificationLaunchApp ?? false) && payload != null && payload.isNotEmpty) {
        opened.value = payload;
      }
      _ready = true;
    } catch (e) {
      _log.warning('init: $e');
    }
  }

  /// Android 13+: asks for the notification permission (once; the system
  /// does not ask again after a refusal).
  Future<void> requestPermission() async {
    if (!Platform.isAndroid) return;
    await init();
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      _log.debug('permission: $e');
    }
  }

  /// One conversation's notification (each device has its own; a new
  /// message replaces the one before).
  Future<void> show({
    required String device,
    required String title,
    required String body,
    required bool sound,
    required bool vibrate,
  }) async {
    if (appUiVisible.value) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      DesktopNotificationService.instance.notify(title: title, body: body);
      return;
    }
    if (!Platform.isAndroid) return;
    await init();
    if (!_ready) return;
    final id = 'ileti_${sound ? 's' : ''}${vibrate ? 'v' : ''}';
    final name = switch ((sound, vibrate)) {
      (true, true) => 'Mesajlar',
      (true, false) => 'Mesajlar (titreşimsiz)',
      (false, true) => 'Mesajlar (sessiz, titreşimli)',
      (false, false) => 'Mesajlar (sessiz)',
    };
    try {
      await _plugin.show(
        id: device.hashCode & 0x3fffffff,
        title: title,
        body: body,
        payload: device,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            id,
            name,
            channelDescription: 'LifeOS İleti',
            importance: sound || vibrate ? Importance.high : Importance.low,
            priority: sound || vibrate ? Priority.high : Priority.low,
            playSound: sound,
            enableVibration: vibrate,
            silent: !sound && !vibrate,
            category: AndroidNotificationCategory.message,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
      );
    } catch (e) {
      _log.warning('show: $e');
    }
  }

  Future<void> clear(String device) async {
    if (!Platform.isAndroid || !_ready) return;
    try {
      await _plugin.cancel(id: device.hashCode & 0x3fffffff);
    } catch (_) {}
  }
}
