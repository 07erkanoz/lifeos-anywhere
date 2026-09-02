import 'package:flutter_test/flutter_test.dart';

import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';
import 'package:anyware/features/transfer/presentation/transfer_screen.dart';

void main() {
  final now = DateTime(2026, 9, 1, 12);
  final device = Device(
    id: 'device-1',
    name: 'Office PC',
    ip: '192.168.1.20',
    port: 53317,
    platform: 'linux',
    version: '1.0.0',
    lastSeen: now,
  );

  Transfer transfer(
    String id,
    TransferStatus status, {
    int minute = 0,
    String? sourceFilePath,
  }) {
    return Transfer(
      id: id,
      fileName: '$id.txt',
      fileSize: 1024,
      senderDevice: device,
      receiverDevice: device,
      status: status,
      createdAt: now.add(Duration(minutes: minute)),
      sourceFilePath: sourceFilePath,
    );
  }

  test('groups active, attention and completed transfers', () {
    final groups = TransferGroups.from([
      transfer('completed', TransferStatus.completed),
      transfer('cancelled', TransferStatus.cancelled),
      transfer('failed', TransferStatus.failed),
      transfer('rejected', TransferStatus.rejected),
      transfer('pending', TransferStatus.pending),
      transfer('accepted', TransferStatus.accepted),
      transfer('transferring', TransferStatus.transferring),
      transfer('paused', TransferStatus.paused),
    ]);

    expect(groups.active.map((item) => item.status), [
      TransferStatus.pending,
      TransferStatus.accepted,
      TransferStatus.transferring,
      TransferStatus.paused,
    ]);
    expect(groups.attention.map((item) => item.status), [
      TransferStatus.cancelled,
      TransferStatus.failed,
      TransferStatus.rejected,
    ]);
    expect(groups.completed.single.status, TransferStatus.completed);
  });

  test('sorts every group newest first without mutating input', () {
    final older = transfer('older', TransferStatus.transferring);
    final newer = transfer('newer', TransferStatus.pending, minute: 2);
    final input = [older, newer];

    final groups = TransferGroups.from(input);

    expect(groups.active.map((item) => item.id), ['newer', 'older']);
    expect(input.map((item) => item.id), ['older', 'newer']);
  });

  test('preserves outgoing source path through JSON serialization', () {
    final original = transfer(
      'retryable',
      TransferStatus.failed,
      sourceFilePath: '/tmp/source.txt',
    );

    final restored = Transfer.fromJson(original.toJson());

    expect(restored.sourceFilePath, '/tmp/source.txt');
  });
}
