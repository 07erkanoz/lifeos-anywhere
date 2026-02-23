import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/timeline/domain/timeline_event.dart';
import 'package:anyware/features/timeline/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

class TimelineScreen extends ConsumerWidget {
  const TimelineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(timelineProvider);
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('timeline', locale)),
      ),
      body: events.isEmpty
          ? _EmptyTimeline(locale: locale, isDark: isDark)
          : _TimelineList(events: events, isDark: isDark, locale: locale),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline({required this.locale, required this.isDark});

  final String locale;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.timeline_rounded,
              size: 56,
              color: isDark ? AppColors.textTertiary : Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.get('timelineEmpty', locale),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: isDark ? AppColors.textSecondary : Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.get('timelineEmptyDesc', locale),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppColors.textTertiary : Colors.grey.shade400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Timeline list grouped by date
// ---------------------------------------------------------------------------

class _TimelineList extends StatelessWidget {
  const _TimelineList({
    required this.events,
    required this.isDark,
    required this.locale,
  });

  final List<TimelineEvent> events;
  final bool isDark;
  final String locale;

  @override
  Widget build(BuildContext context) {
    // Group events by date.
    final grouped = <String, List<TimelineEvent>>{};
    for (final event in events) {
      final key = DateFormat('yyyy-MM-dd').format(event.timestamp);
      grouped.putIfAbsent(key, () => []).add(event);
    }

    final dateKeys = grouped.keys.toList();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: dateKeys.length,
      itemBuilder: (context, index) {
        final dateKey = dateKeys[index];
        final dayEvents = grouped[dateKey]!;
        final date = DateTime.parse(dateKey);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Date header
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text(
                _formatDateHeader(date, locale),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppColors.textSecondary : Colors.grey.shade600,
                ),
              ),
            ),
            // Events for this date
            ...dayEvents.map((event) => _TimelineEventCard(
                  event: event,
                  isDark: isDark,
                  locale: locale,
                )),
          ],
        );
      },
    );
  }

  String _formatDateHeader(DateTime date, String locale) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final eventDate = DateTime(date.year, date.month, date.day);

    if (eventDate == today) {
      return AppLocalizations.get('today', locale);
    }
    if (eventDate == yesterday) {
      return AppLocalizations.get('yesterday', locale);
    }
    return DateFormat.yMMMd().format(date);
  }
}

// ---------------------------------------------------------------------------
// Individual event card
// ---------------------------------------------------------------------------

class _TimelineEventCard extends StatelessWidget {
  const _TimelineEventCard({
    required this.event,
    required this.isDark,
    required this.locale,
  });

  final TimelineEvent event;
  final bool isDark;
  final String locale;

  IconData get _icon {
    switch (event.type) {
      case TimelineEventType.fileSent:
        return Icons.upload_rounded;
      case TimelineEventType.fileReceived:
        return Icons.download_rounded;
      case TimelineEventType.clipboardSync:
        return Icons.content_paste_rounded;
    }
  }

  Color get _iconColor {
    switch (event.type) {
      case TimelineEventType.fileSent:
        return AppColors.neonBlue;
      case TimelineEventType.fileReceived:
        return AppColors.neonGreen;
      case TimelineEventType.clipboardSync:
        return AppColors.neonPurple;
    }
  }

  String get _typeLabel {
    switch (event.type) {
      case TimelineEventType.fileSent:
        return AppLocalizations.get('sentTo', locale);
      case TimelineEventType.fileReceived:
        return AppLocalizations.get('receivedFrom', locale);
      case TimelineEventType.clipboardSync:
        return AppLocalizations.get('clipboard', locale);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? AppColors.glassBorder : Colors.grey.shade200,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _iconColor.withValues(alpha: 0.15),
              ),
              child: Icon(_icon, size: 18, color: _iconColor),
            ),
            const SizedBox(width: 12),

            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: isDark ? AppColors.textPrimary : Colors.black87,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '$_typeLabel ${event.subtitle}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? AppColors.textSecondary
                              : Colors.grey.shade600,
                        ),
                      ),
                      if (event.formattedSize.isNotEmpty) ...[
                        Text(
                          ' · ${event.formattedSize}',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? AppColors.textTertiary
                                : Colors.grey.shade400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Time & status
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  DateFormat.Hm().format(event.timestamp),
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textTertiary
                        : Colors.grey.shade400,
                  ),
                ),
                if (!event.succeeded)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Icon(
                      Icons.error_outline_rounded,
                      size: 14,
                      color: Colors.red.shade400,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
