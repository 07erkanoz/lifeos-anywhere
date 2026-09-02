import 'package:anyware/features/transfer/presentation/file_preview_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classifies formats supported by the in-app preview', () {
    expect(filePreviewKind('/tmp/photo.jpg'), FilePreviewKind.image);
    expect(filePreviewKind('/tmp/document.pdf'), FilePreviewKind.pdf);
    expect(filePreviewKind('/tmp/movie.mp4'), FilePreviewKind.video);
    expect(filePreviewKind('/tmp/sound.mp3'), FilePreviewKind.audio);
    expect(filePreviewKind('/tmp/notes.md'), FilePreviewKind.text);
    expect(filePreviewKind('/tmp/archive.zip'), FilePreviewKind.unsupported);
  });
}
