import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:anyware/app.dart';
import 'package:anyware/core/tv_detector.dart';
import 'package:anyware/features/discovery/presentation/device_list_screen.dart';
import 'package:anyware/features/platform/tray_service.dart';
import 'package:anyware/features/platform/windows/notification_service.dart';
import 'package:anyware/features/platform/windows/windows_service.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/settings/domain/settings.dart';

final _log = AppLogger('Main');

/// Global provider container so the single-instance TCP listener can push
/// file paths into the widget tree from outside the Flutter framework.
late final ProviderContainer _container;

/// Buffer for accumulating file paths from multiple rapid Explorer context
/// menu invocations (Windows launches one process per selected file).
final List<String> _pendingSharePaths = [];
Timer? _shareDebounce;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Obtain the SharedPreferences instance before building the widget tree.
  final prefs = await SharedPreferences.getInstance();

  // --- Android-specific initialisation ---
  if (Platform.isAndroid) {
    // TV detection.
    await TvDetector.isAndroidTV();
    if (TvDetector.isTVCached) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.leanBack);
    }

    // Request storage permission at startup so file transfers work.
    await _requestAndroidStoragePermission();
  }

  // File path from --share argument (Explorer context menu).
  String? pendingSharePath;

  // --- Windows-specific initialisation ---
  if (Platform.isWindows) {
    // Single instance check. If another instance is running, forward args
    // and exit.
    final alreadyRunning = await _checkSingleInstance(args);
    if (alreadyRunning) {
      exit(0);
    }

    await windowManager.ensureInitialized();

    // Sidebar + content area comfortably fit at this size.
    const windowSize = Size(720, 680);
    await windowManager.setSize(windowSize);
    await windowManager.setMinimumSize(const Size(560, 560));
    await windowManager.center();
    await windowManager.setTitle('LifeOS AnyWhere');
    await windowManager.setPreventClose(true);

    // Use hidden titlebar for a modern, frameless look on Windows 11.
    // The app draws its own titlebar with window controls.
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );

    // Load persisted settings so we can pass them to WindowsService.
    final settingsRepo = SettingsRepository(prefs);
    final AppSettings settings = await settingsRepo.load();

    final windowsService = WindowsService();
    try {
      await windowsService.init(settings);
    } catch (e) {
      _log.error('WindowsService.init failed', error: e);
    }

    final bool shouldShowWindow = windowsService.handleStartupArgs(args);

    if (!shouldShowWindow) {
      await windowManager.hide();
    }

    // Extract --share file path from first-instance launch.
    final shareIndex = args.indexOf('--share');
    if (shareIndex != -1 && shareIndex + 1 < args.length) {
      pendingSharePath = args[shareIndex + 1];
    }

    // Initialize Windows toast notifications.
    try {
      await WindowsNotificationService.instance.init();
    } catch (e) {
      _log.error('WindowsNotificationService.init failed', error: e);
    }
  }

  // --- Linux / macOS desktop initialisation ---
  if (Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();

    const windowSize = Size(720, 680);
    await windowManager.setSize(windowSize);
    await windowManager.setMinimumSize(const Size(560, 560));
    await windowManager.center();
    await windowManager.setTitle('LifeOS AnyWhere');
    await windowManager.setPreventClose(true);

    // Load settings for tray configuration.
    final settingsRepo = SettingsRepository(prefs);
    final AppSettings settings = await settingsRepo.load();

    // Initialize platform-agnostic system tray (Linux/macOS).
    if (settings.minimizeToTray) {
      final tray = AppTrayService();
      try {
        await tray.initTray();
        await tray.setupCloseToTray();
      } catch (e) {
        _log.error('AppTrayService.init failed', error: e);
      }
    }
  }

  _container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ],
  );

  // Set pending share path if launched with --share.
  if (pendingSharePath != null) {
    _container.read(pendingShareProvider.notifier).state = [pendingSharePath];
  }

  runApp(
    UncontrolledProviderScope(
      container: _container,
      child: const App(),
    ),
  );
}

/// Requests storage permissions on Android.
///
/// On Android 11+ (API 30+), requests MANAGE_EXTERNAL_STORAGE which gives
/// broad file access. On older versions, requests READ/WRITE_EXTERNAL_STORAGE.
///
/// The request is non-blocking: if the user denies, the app still launches
/// but file transfers may fail until permission is granted from Settings.
Future<void> _requestAndroidStoragePermission() async {
  // Try MANAGE_EXTERNAL_STORAGE first (Android 11+).
  final manageStatus = await Permission.manageExternalStorage.status;
  if (!manageStatus.isGranted) {
    final result = await Permission.manageExternalStorage.request();
    if (result.isGranted) return;
  } else {
    return; // Already granted.
  }

  // Fallback: request classic storage permission (Android 10 and below).
  final storageStatus = await Permission.storage.status;
  if (!storageStatus.isGranted) {
    await Permission.storage.request();
  }
}

/// Tries to bind a TCP server on a fixed local port to act as a single-instance
/// mutex. Returns `true` if another instance is already running.
///
/// Protocol:
/// - `SHOW` → bring existing window to front
/// - `SHARE:<path>` → bring window to front and trigger device picker for file
Future<bool> _checkSingleInstance(List<String> args) async {
  try {
    // Use a fixed port just for the single-instance lock (loopback only).
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      42099,
      shared: false,
    );
    // We got the lock — keep it alive for the app's lifetime.
    // When another instance connects, read the message and act on it.
    server.listen((socket) {
      final buffer = StringBuffer();
      socket.listen(
        (data) {
          buffer.write(utf8.decode(data));
        },
        onDone: () {
          final message = buffer.toString().trim();
          _handleInstanceMessage(message);
          socket.close();
        },
        onError: (_) => socket.close(),
      );
    });
    return false; // We are the first instance.
  } on SocketException {
    // Port already in use — another instance is running.
    // Forward our args to the running instance.
    try {
      final socket =
          await Socket.connect(InternetAddress.loopbackIPv4, 42099);

      // Check if we have a --share argument to forward.
      final shareIndex = args.indexOf('--share');
      if (shareIndex != -1 && shareIndex + 1 < args.length) {
        socket.write('SHARE:${args[shareIndex + 1]}');
      } else {
        socket.write('SHOW');
      }
      await socket.flush();
      await socket.close();
    } catch (_) {}
    return true; // Another instance exists.
  }
}

/// Handles a message received from a second app instance via TCP.
///
/// When the user selects multiple files in Explorer and clicks the context
/// menu item, Windows launches one process per file. Each secondary instance
/// sends a `SHARE:<path>` message here in rapid succession. We accumulate
/// all paths in a buffer and flush them into the provider after a short
/// debounce window (300 ms) so the device picker receives all files at once.
void _handleInstanceMessage(String message) {
  // Always bring the window to the front.
  windowManager.show();
  windowManager.focus();

  if (message.startsWith('SHARE:')) {
    final filePath = message.substring(6).trim();
    if (filePath.isNotEmpty) {
      _pendingSharePaths.add(filePath);
      _shareDebounce?.cancel();
      _shareDebounce = Timer(const Duration(milliseconds: 300), () {
        final paths = List<String>.from(_pendingSharePaths);
        _pendingSharePaths.clear();
        _container.read(pendingShareProvider.notifier).state = paths;
      });
    }
  }
}
