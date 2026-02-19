import 'package:flutter/material.dart';

import 'package:anyware/features/discovery/domain/device.dart';

/// A reusable card widget that displays a discovered device on the network.
class DeviceCard extends StatelessWidget {
  final Device device;
  final VoidCallback? onTap;
  final VoidCallback? onSendFile;

  const DeviceCard({
    super.key,
    required this.device,
    this.onTap,
    this.onSendFile,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Platform icon with online indicator
              Stack(
                children: [
                  CircleAvatar(
                    backgroundColor: colorScheme.primaryContainer,
                    foregroundColor: colorScheme.onPrimaryContainer,
                    child: Icon(_platformIconData(device.platformIcon)),
                  ),
                  if (device.isOnline)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorScheme.surface,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 16),

              // Device name and details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      device.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${device.ip} \u00b7 ${device.platformLabel}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // Send file button
              if (onSendFile != null)
                IconButton(
                  onPressed: onSendFile,
                  icon: const Icon(Icons.send),
                  tooltip: 'Send file',
                  style: IconButton.styleFrom(
                    foregroundColor: colorScheme.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Maps a platform icon string to the corresponding [IconData].
  IconData _platformIconData(String platformIcon) {
    switch (platformIcon) {
      case 'phone_android':
        return Icons.phone_android;
      case 'tv':
        return Icons.tv;
      case 'desktop_windows':
        return Icons.desktop_windows;
      case 'phone_iphone':
        return Icons.phone_iphone;
      case 'computer':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }
}
