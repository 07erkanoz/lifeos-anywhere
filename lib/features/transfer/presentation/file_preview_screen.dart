import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:video_player/video_player.dart';

import 'package:anyware/core/responsive.dart';
import 'package:anyware/i18n/app_localizations.dart';

enum FilePreviewKind { image, pdf, video, audio, text, unsupported }

FilePreviewKind filePreviewKind(String path) {
  final mimeType = lookupMimeType(path)?.toLowerCase();
  final extension = p.extension(path).toLowerCase();
  if (mimeType?.startsWith('image/') ?? false) return FilePreviewKind.image;
  if (mimeType == 'application/pdf' || extension == '.pdf') {
    return FilePreviewKind.pdf;
  }
  if (mimeType?.startsWith('video/') ?? false) return FilePreviewKind.video;
  if (mimeType?.startsWith('audio/') ?? false) return FilePreviewKind.audio;
  if (mimeType?.startsWith('text/') ??
      false ||
          const {
            '.json',
            '.xml',
            '.yaml',
            '.yml',
            '.md',
            '.csv',
            '.log',
            '.ini',
            '.conf',
            '.dart',
            '.kt',
            '.java',
            '.js',
            '.ts',
            '.css',
            '.html',
          }.contains(extension)) {
    return FilePreviewKind.text;
  }
  return FilePreviewKind.unsupported;
}

bool canPreviewFile(String path) =>
    filePreviewKind(path) != FilePreviewKind.unsupported;

class FilePreviewScreen extends StatelessWidget {
  const FilePreviewScreen({
    super.key,
    required this.path,
    required this.locale,
    this.onOpenExternally,
  });

  final String path;
  final String locale;
  final Future<void> Function()? onOpenExternally;

  @override
  Widget build(BuildContext context) {
    final kind = filePreviewKind(path);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          p.basename(path),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (onOpenExternally != null)
            IconButton(
              tooltip: AppLocalizations.get('openExternally', locale),
              onPressed: onOpenExternally,
              icon: const Icon(Icons.open_in_new_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: switch (kind) {
          FilePreviewKind.image => _ImagePreview(path: path, locale: locale),
          FilePreviewKind.pdf => PdfViewer.file(path),
          FilePreviewKind.video => _MediaPreview(
            path: path,
            locale: locale,
            showVideo: true,
          ),
          FilePreviewKind.audio => _MediaPreview(
            path: path,
            locale: locale,
            showVideo: false,
          ),
          FilePreviewKind.text => _TextPreview(path: path, locale: locale),
          FilePreviewKind.unsupported => _PreviewError(locale: locale),
        },
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.path, required this.locale});

  final String path;
  final String locale;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) =>
                _PreviewError(locale: locale),
          ),
        ),
      ),
    );
  }
}

class _TextPreview extends StatefulWidget {
  const _TextPreview({required this.path, required this.locale});

  final String path;
  final String locale;

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  static const _maxPreviewBytes = 1024 * 1024;
  final _scrollController = ScrollController();
  late final Future<String> _content = _readPreview();

  Future<String> _readPreview() async {
    final file = File(widget.path);
    final handle = await file.open();
    try {
      final bytes = await handle.read(_maxPreviewBytes);
      final text = utf8.decode(bytes, allowMalformed: true);
      final isTruncated = await file.length() > bytes.length;
      return isTruncated ? '$text\n\n…' : text;
    } finally {
      await handle.close();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => 1.0,
      LogicalKeyboardKey.arrowUp => -1.0,
      _ => 0.0,
    };
    if (direction == 0) return KeyEventResult.ignored;
    final next = (_scrollController.offset + (180 * direction)).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      next,
      duration: context.motionDuration(AppMotion.standard),
      curve: Curves.easeOut,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _content,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _PreviewError(locale: widget.locale);
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return Focus(
          autofocus: true,
          onKeyEvent: _handleKey,
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: EdgeInsets.all(context.adaptivePagePadding),
              child: SelectableText(
                snapshot.data!,
                style: const TextStyle(fontFamily: 'monospace', height: 1.45),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MediaPreview extends StatefulWidget {
  const _MediaPreview({
    required this.path,
    required this.locale,
    required this.showVideo,
  });

  final String path;
  final String locale;
  final bool showVideo;

  @override
  State<_MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<_MediaPreview> {
  late final VideoPlayerController _controller = VideoPlayerController.file(
    File(widget.path),
  );
  late final Future<void> _initialized = _controller.initialize();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayback() {
    if (!_controller.value.isInitialized) return;
    _controller.value.isPlaying ? _controller.pause() : _controller.play();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initialized,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _PreviewError(locale: widget.locale);
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final value = _controller.value;
            return Column(
              children: [
                Expanded(
                  child: Center(
                    child: widget.showVideo
                        ? AspectRatio(
                            aspectRatio: value.aspectRatio == 0
                                ? 16 / 9
                                : value.aspectRatio,
                            child: VideoPlayer(_controller),
                          )
                        : Icon(
                            Icons.graphic_eq_rounded,
                            size: 112,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: Column(
                    children: [
                      VideoProgressIndicator(
                        _controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      FilledButton.icon(
                        autofocus: true,
                        onPressed: _togglePlayback,
                        icon: Icon(
                          value.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        label: Text(
                          AppLocalizations.get(
                            value.isPlaying ? 'pause' : 'play',
                            widget.locale,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _PreviewError extends StatelessWidget {
  const _PreviewError({required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.visibility_off_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.get('previewUnavailable', locale),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
