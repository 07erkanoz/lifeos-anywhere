import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';

/// Camera to PDF (as LifeOS Folio): Google's ML Kit document scanner finds
/// each page's edges, straightens it, takes as many pages as wanted and
/// gives one PDF. It runs in Google Play services' own screen, so no camera
/// permission is asked here. Android only.
class DocumentScan {
  DocumentScan._();

  static bool get available => Platform.isAndroid;

  static const _platform = MethodChannel('com.lifeos.anyware/platform');

  /// Scans and saves the PDF in [folder]/Taramalar; its path, or null when
  /// the scan was given up. Throws [StateError] when the scanner cannot open.
  static Future<String?> toPdf(String folder) async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.pdf},
        pageLimit: 100,
        isGalleryImport: true,
      ),
    );
    try {
      final DocumentScanningResult result;
      try {
        result = await scanner.scanDocument();
      } on PlatformException catch (e) {
        if ((e.message ?? '').toLowerCase().contains('cancel')) return null;
        throw StateError('scanner: ${e.message}');
      }
      final uri = result.pdf?.uri;
      if (uri == null) return null;
      final source = File(uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : uri);
      final dir = Directory('$folder${Platform.pathSeparator}Taramalar');
      await dir.create(recursive: true);
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stem = 'Tarama ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}.${two(now.minute)}';
      var target = File('${dir.path}${Platform.pathSeparator}$stem.pdf');
      for (var i = 2; target.existsSync(); i++) {
        target = File('${dir.path}${Platform.pathSeparator}$stem ($i).pdf');
      }
      try {
        await source.copy(target.path);
      } finally {
        // the scanner's copy sits in the app cache
        if (await source.exists()) await source.delete();
      }
      // into the gallery / file managers at once
      try {
        await _platform.invokeMethod<String>('scanFile', {'path': target.path});
      } catch (_) {}
      return target.path;
    } finally {
      await scanner.close();
    }
  }
}

/// The scanned PDFs (<downloads>/Taramalar), newest first.
List<File> listScans(String downloadPath) {
  final dir = Directory('$downloadPath${Platform.pathSeparator}Taramalar');
  if (downloadPath.isEmpty || !dir.existsSync()) return const [];
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.pdf'))
      .map((f) => (f, f.statSync().modified))
      .toList()
    ..sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (f, _) in files) f];
}
