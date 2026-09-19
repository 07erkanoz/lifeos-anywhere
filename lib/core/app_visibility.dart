import 'package:flutter/foundation.dart';

/// Whether the app's UI is currently on screen.
///
/// Desktop windows keep running after being minimized or hidden to the system
/// tray, and Flutter keeps driving tickers in that state. Continuous
/// animations must pause while this is false — otherwise they rebuild and
/// repaint every frame for a surface nobody is looking at, which keeps the
/// CPU and GPU awake and drains battery on laptops.
///
/// Updated from `_MainShellState` via the app lifecycle observer and the
/// `window_manager` minimize/restore/focus events.
final ValueNotifier<bool> appUiVisible = ValueNotifier<bool>(true);
