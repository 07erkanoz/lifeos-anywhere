import 'package:flutter_test/flutter_test.dart';

import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/transfer/data/file_sender.dart';
import 'package:anyware/features/transfer/data/transfer_queue.dart';

void main() {
  late FileSender sender;
  late TransferQueue queue;

  setUp(() {
    final device = Device(
      id: 'device',
      name: 'Desktop',
      ip: '127.0.0.1',
      port: 53317,
      platform: 'linux',
      version: 'test',
      lastSeen: DateTime(2026, 9, 1),
    );
    sender = FileSender(localDevice: device);
    queue = TransferQueue(sender: sender, autoStart: false);
  });

  tearDown(() {
    queue.dispose();
    sender.dispose();
  });

  test('moves waiting files without losing queue entries', () {
    final first = queue.enqueue(sender.localDevice, '/tmp/first.txt');
    final second = queue.enqueue(sender.localDevice, '/tmp/second.txt');
    final third = queue.enqueue(sender.localDevice, '/tmp/third.txt');

    expect(queue.move(third.id, -1), isTrue);
    expect(queue.pending.map((item) => item.id), [
      first.id,
      third.id,
      second.id,
    ]);

    expect(queue.move(third.id, -1), isTrue);
    expect(queue.pending.map((item) => item.id), [
      third.id,
      first.id,
      second.id,
    ]);
    expect(queue.move(third.id, -1), isFalse);
  });

  test('removes one waiting file and rejects unknown entries', () {
    final first = queue.enqueue(sender.localDevice, '/tmp/first.txt');
    final second = queue.enqueue(sender.localDevice, '/tmp/second.txt');

    expect(queue.remove(first.id), isTrue);
    expect(queue.pending.single.id, second.id);
    expect(queue.remove('missing'), isFalse);
  });

  test('cancel all clears every waiting file', () {
    queue.enqueue(sender.localDevice, '/tmp/first.txt');
    queue.enqueue(sender.localDevice, '/tmp/second.txt');

    queue.cancelAll();

    expect(queue.pending, isEmpty);
  });

  test('pins the sending item while clearing files behind it', () {
    final sending = queue.enqueue(sender.localDevice, '/tmp/sending.txt');
    final waiting = queue.enqueue(sender.localDevice, '/tmp/waiting.txt');
    sending.status = QueueStatus.sending;

    expect(queue.move(sending.id, 1), isFalse);
    expect(queue.move(waiting.id, -1), isFalse);

    queue.cancelAll();

    expect(queue.pending.single.id, sending.id);
  });
}
