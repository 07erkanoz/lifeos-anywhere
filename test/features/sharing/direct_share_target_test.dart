import 'package:anyware/features/platform/android/direct_share_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the selected Android Direct Share target', () {
    final target = DirectShareTargetInfo.fromMap(const {
      'id': 'device-42',
      'name': 'Salon PC',
      'ip': '192.168.1.42',
    });

    expect(target.id, 'device-42');
    expect(target.name, 'Salon PC');
    expect(target.ip, '192.168.1.42');
  });
}
