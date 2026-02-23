import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/features/transfer/data/transfer_history.dart';
import 'package:anyware/features/clipboard/data/clipboard_service.dart';
import 'package:anyware/features/timeline/domain/timeline_event.dart';

/// Provides a merged, chronologically sorted list of all activity events.
final timelineProvider = Provider<List<TimelineEvent>>((ref) {
  final transfers = ref.watch(transferHistoryProvider);
  final clipboard = ref.watch(clipboardHistoryProvider);

  final events = <TimelineEvent>[
    ...transfers.map(TimelineEvent.fromTransfer),
    ...clipboard.map(TimelineEvent.fromClipboard),
  ];

  events.sort(); // Newest first (compareTo in TimelineEvent).

  return events;
});
