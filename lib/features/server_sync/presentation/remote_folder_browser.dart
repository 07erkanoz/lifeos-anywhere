import 'package:flutter/material.dart';

import 'package:anyware/features/server_sync/data/cloud_transport.dart';
import 'package:anyware/i18n/app_localizations.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Remote Folder Browser Dialog
// ═══════════════════════════════════════════════════════════════════════════════

/// Shows a dialog that lets the user browse a remote file system and pick a
/// folder.  Works with any [RemoteBrowser] implementation (SFTP, LAN, Google
/// Drive, OneDrive).
///
/// Returns the selected path, or `null` if the user cancelled.
Future<String?> showRemoteFolderPicker(
  BuildContext context, {
  required RemoteBrowser browser,
  required String title,
  String? initialPath,
  Color? accentColor,
  String locale = 'en',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => RemoteFolderBrowser(
      browser: browser,
      title: title,
      initialPath: initialPath,
      accentColor: accentColor ?? Theme.of(context).colorScheme.primary,
      locale: locale,
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Widget
// ═══════════════════════════════════════════════════════════════════════════════

/// A full-screen-ish dialog that browses a [RemoteBrowser]'s directory tree.
class RemoteFolderBrowser extends StatefulWidget {
  /// The remote browser to use for listing directories.
  final RemoteBrowser browser;

  /// Dialog title, e.g. "Browse Google Drive".
  final String title;

  /// Optional starting path (defaults to [browser.rootPath]).
  final String? initialPath;

  /// Accent colour for selection highlight and action buttons.
  final Color accentColor;

  /// Current locale code for i18n.
  final String locale;

  const RemoteFolderBrowser({
    super.key,
    required this.browser,
    required this.title,
    this.initialPath,
    required this.accentColor,
    this.locale = 'en',
  });

  @override
  State<RemoteFolderBrowser> createState() => _RemoteFolderBrowserState();
}

class _RemoteFolderBrowserState extends State<RemoteFolderBrowser> {
  late String _currentPath;
  List<RemoteEntry> _entries = [];
  bool _isLoading = true;
  String? _error;
  String? _selectedPath;

  /// Breadcrumb segments: list of (label, fullPath) pairs.
  List<_Crumb> _breadcrumbs = [];

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath ?? widget.browser.rootPath;
    _buildBreadcrumbs();
    _loadDirectory(_currentPath);
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final entries = await widget.browser.listDirectory(path);
      if (!mounted) return;
      setState(() {
        _currentPath = path;
        _entries = entries;
        _isLoading = false;
        _selectedPath = null;
        _buildBreadcrumbs();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  void _buildBreadcrumbs() {
    final crumbs = <_Crumb>[];
    crumbs.add(_Crumb(label: 'Root', path: widget.browser.rootPath));

    if (_currentPath.isNotEmpty && _currentPath != widget.browser.rootPath) {
      // Normalise separators to '/'
      final normalised = _currentPath.replaceAll('\\', '/');
      final root = widget.browser.rootPath.replaceAll('\\', '/');
      final relative =
          normalised.startsWith(root) && root.isNotEmpty
              ? normalised.substring(root.length)
              : normalised;

      final parts =
          relative.split('/').where((p) => p.isNotEmpty).toList();

      var accumulated = root.isEmpty ? '' : root;
      for (final part in parts) {
        accumulated =
            accumulated.endsWith('/') ? '$accumulated$part' : '$accumulated/$part';
        crumbs.add(_Crumb(label: part, path: accumulated));
      }
    }

    _breadcrumbs = crumbs;
  }

  void _navigateTo(String path) {
    _loadDirectory(path);
  }

  void _goUp() {
    if (_breadcrumbs.length > 1) {
      _navigateTo(_breadcrumbs[_breadcrumbs.length - 2].path);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1A1A2E) : Colors.white;
    final cardColor =
        isDark ? Colors.white.withValues(alpha: 0.06) : Colors.grey.shade50;
    final locale = widget.locale;

    return Dialog(
      backgroundColor: bgColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 520,
          maxHeight: 560,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Title bar ──
            _buildTitleBar(isDark, locale),
            const Divider(height: 1),

            // ── Breadcrumb ──
            _buildBreadcrumbBar(isDark),
            const Divider(height: 1),

            // ── Content ──
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _buildErrorState(isDark)
                      : _entries.isEmpty
                          ? _buildEmptyState(isDark, locale)
                          : _buildEntryList(isDark, cardColor),
            ),

            // ── Actions ──
            const Divider(height: 1),
            _buildActionBar(isDark, locale),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBar(bool isDark, String locale) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
      child: Row(
        children: [
          Icon(Icons.folder_open_rounded,
              size: 22, color: widget.accentColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: AppLocalizations.get('cancel', locale),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumbBar(bool isDark) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          // Up button
          IconButton(
            icon: const Icon(Icons.arrow_upward_rounded, size: 18),
            onPressed: _breadcrumbs.length > 1 ? _goUp : null,
            tooltip: 'Go up',
            visualDensity: VisualDensity.compact,
          ),
          const VerticalDivider(width: 1),

          // Breadcrumb chips
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _breadcrumbs.length,
              separatorBuilder: (_, _) => Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
              ),
              itemBuilder: (_, i) {
                final crumb = _breadcrumbs[i];
                final isLast = i == _breadcrumbs.length - 1;
                return Center(
                  child: InkWell(
                    onTap: isLast ? null : () => _navigateTo(crumb.path),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Text(
                        crumb.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              isLast ? FontWeight.w600 : FontWeight.normal,
                          color: isLast
                              ? null
                              : (isDark
                                  ? Colors.grey.shade400
                                  : Colors.grey.shade600),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 18),
            onPressed: () => _loadDirectory(_currentPath),
            tooltip: 'Refresh',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildEntryList(bool isDark, Color cardColor) {
    // Only show directories (this is a folder picker, not a file picker)
    final dirs = _entries.where((e) => e.isDirectory).toList();
    final files = _entries.where((e) => !e.isDirectory).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        // Directories
        for (final entry in dirs)
          _buildEntryTile(entry, isDark, cardColor, isDir: true),

        // Files (dimmed, not selectable — shown for context)
        if (files.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '${files.length} file${files.length == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.grey.shade600 : Colors.grey.shade500,
              ),
            ),
          ),
          for (final entry in files)
            _buildEntryTile(entry, isDark, cardColor, isDir: false),
        ],
      ],
    );
  }

  Widget _buildEntryTile(
    RemoteEntry entry,
    bool isDark,
    Color cardColor, {
    required bool isDir,
  }) {
    final isSelected = _selectedPath == entry.path;
    final selectedBg =
        widget.accentColor.withValues(alpha: isDark ? 0.15 : 0.08);

    return ListTile(
      dense: true,
      leading: Icon(
        isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
        size: 20,
        color: isDir
            ? widget.accentColor
            : (isDark ? Colors.grey.shade500 : Colors.grey.shade400),
      ),
      title: Text(
        entry.name,
        style: TextStyle(
          fontSize: 13,
          color: isDir
              ? null
              : (isDark ? Colors.grey.shade500 : Colors.grey.shade400),
        ),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: !isDir && entry.size != null
          ? Text(_formatSize(entry.size!),
              style: TextStyle(
                  fontSize: 11,
                  color:
                      isDark ? Colors.grey.shade600 : Colors.grey.shade500))
          : null,
      trailing: isDir
          ? Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: isDark ? Colors.grey.shade500 : Colors.grey.shade400,
            )
          : null,
      tileColor: isSelected ? selectedBg : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onTap: isDir
          ? () {
              setState(() => _selectedPath = entry.path);
            }
          : null,
      onLongPress: isDir ? () => _navigateTo(entry.path) : null,
      // Double-tap to enter folder (desktop)
    );
  }

  Widget _buildEmptyState(bool isDark, String locale) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_off_rounded,
              size: 48,
              color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(
            AppLocalizations.get('emptyFolder', locale),
            style: TextStyle(
              color: isDark ? Colors.grey.shade500 : Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 48, color: Colors.red.shade400),
            const SizedBox(height: 12),
            Text(
              _error ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => _loadDirectory(_currentPath),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionBar(bool isDark, String locale) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Current path info
          Expanded(
            child: Text(
              _selectedPath ?? _currentPath,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.grey.shade500 : Colors.grey.shade500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),

          // Use current folder button
          TextButton(
            onPressed: () => Navigator.of(context).pop(_currentPath),
            child: Text(AppLocalizations.get('remoteBrowseUseCurrent', locale)),
          ),
          const SizedBox(width: 8),

          // Select button (for selected subfolder)
          FilledButton.icon(
            onPressed: _selectedPath != null
                ? () => Navigator.of(context).pop(_selectedPath)
                : null,
            icon: const Icon(Icons.check_rounded, size: 16),
            label: Text(AppLocalizations.get('select', locale)),
            style: FilledButton.styleFrom(
              backgroundColor: widget.accentColor,
            ),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════════

class _Crumb {
  final String label;
  final String path;
  const _Crumb({required this.label, required this.path});
}
