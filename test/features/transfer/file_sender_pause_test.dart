import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/transfer/data/file_sender.dart';
import 'package:anyware/features/transfer/data/file_server.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';

void main() {
  test('pauses an upload and resumes it from the receiver offset', () async {
    final tempDir = await Directory.systemTemp.createTemp('lifeos_pause_test_');
    final downloadDir = Directory('${tempDir.path}/downloads')..createSync();
    final sourceFile = File('${tempDir.path}/source.bin');
    final sourceBytes = List<int>.generate(1024 * 1024, (index) => index % 251);
    await sourceFile.writeAsBytes(sourceBytes, flush: true);

    final now = DateTime.now();
    final receiver = Device(
      id: 'receiver',
      name: 'Receiver',
      ip: InternetAddress.loopbackIPv4.address,
      port: 0,
      platform: 'linux',
      version: 'test',
      lastSeen: now,
    );
    final senderDevice = Device(
      id: 'sender',
      name: 'Sender',
      ip: InternetAddress.loopbackIPv4.address,
      port: 0,
      platform: 'linux',
      version: 'test',
      lastSeen: now,
    );

    final server = FileServer(
      localDevice: receiver,
      downloadPath: downloadDir.path,
      overwriteFiles: true,
    );
    await server.start(0);

    final sender = FileSender(localDevice: senderDevice)
      ..maxUploadSpeedKBps = 512;
    addTearDown(() async {
      sender.dispose();
      await server.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final target = receiver.copyWith(port: server.boundPort!);
    final firstProgress = sender.progressUpdates.firstWhere(
      (transfer) =>
          transfer.status == TransferStatus.transferring &&
          transfer.progress > 0,
    );
    final pausedUpdate = sender.progressUpdates.firstWhere(
      (transfer) => transfer.status == TransferStatus.paused,
    );
    var finished = false;
    final resultFuture = sender.sendFile(target, sourceFile.path)
      ..whenComplete(() => finished = true);
    final active = await firstProgress.timeout(const Duration(seconds: 5));

    expect(await sender.pauseTransfer(active.id), isTrue);
    final paused = await pausedUpdate.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(paused.progress, greaterThan(0));
    expect(finished, isFalse);
    final resumedUpdate = sender.progressUpdates.firstWhere(
      (transfer) => transfer.status == TransferStatus.transferring,
    );
    expect(sender.resumeTransfer(paused.id), isTrue);

    final resumed = await resumedUpdate.timeout(const Duration(seconds: 5));
    final result = await resultFuture.timeout(const Duration(seconds: 10));

    expect(resumed.progress, greaterThanOrEqualTo(paused.progress));
    expect(result.status, TransferStatus.completed);
    expect(
      await File('${downloadDir.path}/source.bin').readAsBytes(),
      sourceBytes,
    );
  }, timeout: const Timeout(Duration(seconds: 20)));
}
