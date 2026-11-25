// File pieces (§2.4) as the faster code seals and opens them: big pieces on
// another isolate, the same bytes as on the UI isolate, tampering caught.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:anyware/features/ileti/data/ileti_crypto.dart';
import 'package:anyware/features/ileti/data/ileti_lan.dart';
import 'package:anyware/features/ileti/data/ileti_posta.dart';

Uint8List _bytes(int n, int seed) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xff));

void main() {
  final key = _bytes(32, 7);
  final prefix = _bytes(4, 3);

  test('boxes open, and a changed byte is refused', () {
    final box = IletiCrypto.seal(key, utf8.encode('merhaba'), utf8.encode('id|from'));
    expect(utf8.decode(IletiCrypto.open(key, box, utf8.encode('id|from'))), 'merhaba');
    box[20] ^= 1;
    expect(() => IletiCrypto.open(key, box, utf8.encode('id|from')), throwsFormatException);
    expect(() => IletiCrypto.open(key, box, utf8.encode('other')), throwsFormatException);
  });

  test('a 1 MiB piece sealed on another isolate opens on this one, and back', () async {
    final block = _bytes(IletiCrypto.chunk, 1);
    final frame = await IletiCrypto.frameAsync(key, prefix, 0, 2, block);
    expect(frame.length, 4 + block.length + 16);
    expect(ByteData.sublistView(frame, 0, 4).getUint32(0), block.length + 16);
    final sealed = Uint8List.sublistView(frame, 4);
    expect(IletiCrypto.openPiece(key, prefix, 0, false, sealed), block);
    expect(await IletiCrypto.openPieceAsync(key, prefix, 0, false, sealed), block);
    // the last piece is sealed apart ("son"): opening it as a middle one fails
    final last = Uint8List.sublistView(IletiCrypto.frame(key, prefix, 1, 2, _bytes(10, 2)), 4);
    expect(() => IletiCrypto.openPiece(key, prefix, 1, false, last), throwsFormatException);
    expect(IletiCrypto.openPiece(key, prefix, 1, true, last), _bytes(10, 2));
  });

  test('sealedFrames: every piece in order, with progress', () async {
    final temp = await Directory.systemTemp.createTemp('ileti_pieces_');
    addTearDown(() => temp.delete(recursive: true));
    final size = IletiCrypto.chunk * 2 + 12345;
    final data = _bytes(size, 5);
    final file = File('${temp.path}/f.bin')..writeAsBytesSync(data);
    final ek = {'key': base64.encode(key), 'nonce': base64.encode(prefix), 'size': size};
    final progress = <double>[];
    final frames = await IletiLan.sealedFrames(file.path, ek, onProgress: progress.add).toList();
    final all = BytesBuilder();
    for (final f in frames) {
      all.add(f);
    }
    final stream = all.takeBytes();
    expect(stream.length, IletiCrypto.streamLength(size));
    // read it back frame by frame
    final out = BytesBuilder();
    var at = 0;
    final total = IletiCrypto.pieces(size);
    for (var n = 0; n < total; n++) {
      final len = ByteData.sublistView(stream, at, at + 4).getUint32(0);
      out.add(IletiCrypto.openPiece(key, prefix, n, n == total - 1, Uint8List.sublistView(stream, at + 4, at + 4 + len)));
      at += 4 + len;
    }
    expect(at, stream.length);
    expect(out.takeBytes(), data);
    expect(progress.last, 1);
    expect(progress, orderedEquals([...progress]..sort()));
  });

  test('the mailbox tries again soon after a failure, then backs off', () {
    expect(IletiPosta.backoff(1), const Duration(seconds: 2));
    expect(IletiPosta.backoff(2), const Duration(seconds: 5));
    expect(IletiPosta.backoff(6), const Duration(seconds: 120));
    expect(IletiPosta.backoff(50), const Duration(seconds: 120));
  });
}
