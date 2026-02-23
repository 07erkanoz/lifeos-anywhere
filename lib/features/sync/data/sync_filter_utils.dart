// Shared file-filter utilities used by both LAN sync and server (SFTP) sync.

/// Top-level directory names that are always excluded from sync.
///
/// Build artifacts, version-control metadata, and dependency caches that would
/// massively inflate file counts and are never useful to sync between devices.
const alwaysExcludeDirs = <String>{
  '.git',
  '.svn',
  '.hg',
  'node_modules',
  '.dart_tool',
  '.gradle',
  'build',
  '__pycache__',
  '.cache',
  '.idea',
  '.vs',
  '.vscode',
};

/// Returns `true` when [relativePath] passes the given include / exclude
/// glob patterns.
bool matchesSyncFilters(
  String relativePath, {
  required List<String> includePatterns,
  required List<String> excludePatterns,
}) {
  // Fast-reject: skip files inside always-excluded directories.
  final firstSegment = relativePath.split('/').first;
  if (alwaysExcludeDirs.contains(firstSegment)) return false;

  if (includePatterns.isNotEmpty) {
    final matches =
        includePatterns.any((pattern) => globMatch(relativePath, pattern));
    if (!matches) return false;
  }
  if (excludePatterns.isNotEmpty) {
    final excluded =
        excludePatterns.any((pattern) => globMatch(relativePath, pattern));
    if (excluded) return false;
  }
  return true;
}

/// Simple glob matching supporting `*` (any segment), `**` (recursive), and
/// `*.ext` (extension). Covers the most common use-cases without pulling in a
/// full glob dependency.
bool globMatch(String path, String pattern) {
  final normPath = path.replaceAll(r'\', '/').toLowerCase();
  final normPattern = pattern.replaceAll(r'\', '/').toLowerCase().trim();

  // Extension match: "*.jpg"
  if (normPattern.startsWith('*.') && !normPattern.contains('/')) {
    return normPath.endsWith(normPattern.substring(1));
  }
  // Recursive directory match: "node_modules/**" or "**/node_modules"
  if (normPattern.contains('**')) {
    final parts = normPattern.split('**');
    if (parts.length == 2) {
      final prefix = parts[0].replaceAll(RegExp(r'/$'), '');
      final suffix = parts[1].replaceAll(RegExp(r'^/'), '');
      if (prefix.isNotEmpty && suffix.isEmpty) {
        return normPath.startsWith('$prefix/') || normPath == prefix;
      }
      if (prefix.isEmpty && suffix.isNotEmpty) {
        return normPath.endsWith(suffix) || normPath.contains('/$suffix');
      }
    }
  }
  // Exact name match (e.g. ".DS_Store", "Thumbs.db").
  if (!normPattern.contains('/') && !normPattern.contains('*')) {
    final fileName = normPath.split('/').last;
    return fileName == normPattern;
  }
  // Fallback: simple contains.
  return normPath.contains(normPattern);
}
