import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';

/// Result of asking another device to pair.
enum PairingResult {
  /// Paired; the token is stored in the [TrustStore].
  paired,

  /// The other device's user declined (or did not answer in time).
  rejected,

  /// The other device runs an old app version without `/api/pair`.
  unsupported,

  /// The device could not be reached.
  failed,
}

/// Client side of device pairing: asks a device to trust us and stores the
/// shared secret it returns.
class PairingClient {
  PairingClient(this.store);

  static final _log = AppLogger('PairingClient');

  final TrustStore store;

  /// Sends `POST /api/pair` to [ip]:[port]. The other device shows a pairing
  /// prompt (or accepts at once when [pairCode] from its QR code is valid),
  /// so this waits up to ~70 s for its user.
  Future<PairingResult> requestPairing({
    required String ip,
    required int port,
    required String localId,
    required String localName,
    required String localPlatform,
    String? pairCode,
  }) async {
    try {
      final response = await http
          .post(
            Uri.http('$ip:$port', '/api/pair'),
            headers: {
              'Content-Type': 'application/json',
              kProtocolHeader: store.authHeaders(null)[kProtocolHeader]!,
            },
            body: jsonEncode({
              'id': localId,
              'name': localName,
              'platform': localPlatform,
              'pairCode': ?pairCode,
            }),
          )
          .timeout(const Duration(seconds: 70));

      if (response.statusCode == 404) return PairingResult.unsupported;
      if (response.statusCode != 200) return PairingResult.failed;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final token = json['token'] as String?;
      final device = json['device'];
      if (json['paired'] != true || token == null || device is! Map) {
        return PairingResult.rejected;
      }
      final peer = Device.fromJson(Map<String, dynamic>.from(device));
      await store.trust(
        id: peer.id,
        name: peer.name,
        platform: peer.platform,
        token: token,
        ip: ip,
      );
      _log.info('Paired with ${peer.name} ($ip)');
      return PairingResult.paired;
    } catch (e) {
      _log.warning('Pairing with $ip failed: $e');
      return PairingResult.failed;
    }
  }

  /// Stores the `pairingToken` a receiver returned in a response body
  /// (send-request / sync setup-request), if any.
  static Future<void> rememberIssuedToken(
    TrustStore? store,
    Device peer,
    Map<String, dynamic> responseJson,
  ) async {
    final token = responseJson['pairingToken'];
    if (store == null || token is! String || token.isEmpty) return;
    await store.trust(
      id: peer.id,
      name: peer.name,
      platform: peer.platform,
      token: token,
      ip: peer.ip,
    );
  }

  /// Whether an HTTP response says the receiver wants us to pair first.
  static bool isPairingRequired(http.Response response) {
    if (response.statusCode != 401 && response.statusCode != 403) {
      return false;
    }
    return response.body.contains('pairing_required');
  }
}
