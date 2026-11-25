import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:anyware/core/tls/tls_identity.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';

/// Capability in the Device JSON: this device answers TLS on its port.
const String kTlsCapability = 'tls';

/// The client side of encryption, as LifeOS's `_connect`: a device whose
/// certificate is pinned is reached only over TLS and only with that
/// certificate; a device that says "tls" but is not pinned yet is reached
/// over TLS and the certificate met is remembered ([seenAt]) so pairing can
/// pin it; any other device is plain HTTP (protocol 1.1).
class PeerTls {
  PeerTls._();

  static final PeerTls instance = PeerTls._();

  /// Set once at start-up; without it nothing is pinned.
  TrustStore? trustStore;

  /// host → the fingerprint a TLS connection to it must show ('' = any).
  final Map<String, String> _expected = {};

  /// host → the fingerprint met on the last TLS connection to it.
  final Map<String, String> _seen = {};

  /// The fingerprint pinned for [deviceId], or `null`.
  String? pinFor(String deviceId) {
    final pin = trustStore?.byId(deviceId)?.fingerprint;
    return pin == null || pin.isEmpty ? null : pin;
  }

  /// Whether [target] is reached over TLS.
  bool usesTls(Device target) =>
      TlsIdentity.current != null &&
      (pinFor(target.id) != null ||
          target.capabilities.contains(kTlsCapability));

  /// The address of [path] on [target]: https or http, see [usesTls].
  Uri uri(
    Device target,
    String path, {
    Map<String, dynamic>? query,
    int? port,
  }) {
    return uriFor(
      target.ip,
      port ?? target.port,
      path,
      deviceId: target.id,
      tls: usesTls(target),
      query: query,
    );
  }

  /// As [uri], for a device known only by address and id.
  Uri uriFor(
    String ip,
    int port,
    String path, {
    String? deviceId,
    bool tls = false,
    Map<String, dynamic>? query,
  }) {
    final pin = deviceId == null ? null : pinFor(deviceId);
    final secure = TlsIdentity.current != null && (tls || pin != null);
    final authority = '$ip:$port';
    if (!secure) return Uri.http(authority, path, query);
    _expected[ip] = pin ?? '';
    return Uri.https(authority, path, query);
  }

  /// An https address on [ip] that only the certificate [fingerprint] may
  /// answer (pairing: the one met a moment ago).
  Uri uriPinned(String ip, int port, String path, String fingerprint) {
    _expected[ip] = fingerprint;
    return Uri.https('$ip:$port', path);
  }

  /// The fingerprint met on the last TLS connection to [host], or ''.
  String seenAt(String host) => _seen[host] ?? '';

  /// An [HttpClient] that checks peers' certificates: no authority is
  /// trusted (a peer's certificate is self-signed, so every TLS connection
  /// comes to [_check]); the pin decides.
  HttpClient httpClient() =>
      HttpClient(context: SecurityContext(withTrustedRoots: false))
        // a peer on this network answers in milliseconds; one that left must
        // not hold a message (or a transfer) for the OS's long TCP timeout
        ..connectionTimeout = const Duration(seconds: 5)
        ..badCertificateCallback = _check;

  /// The same for package:http calls; the caller closes it.
  http.Client client() => IOClient(httpClient());

  /// One package:http client for the whole app (never closed).
  late final http.Client shared = client();

  /// Certificates met, by fingerprint (İleti's pair key needs the peer's
  /// public key: lib/features/ileti/data/ileti_crypto.dart).
  final Map<String, Uint8List> _ders = {};

  /// The certificate (DER) with [fingerprint], if a connection met it.
  Uint8List? certFor(String fingerprint) => _ders[fingerprint];

  bool _check(X509Certificate certificate, String host, int port) {
    final seen = TlsIdentity.fingerprintOf(certificate.der);
    _seen[host] = seen;
    _ders[seen] = certificate.der;
    final expected = _expected[host] ?? '';
    return expected.isEmpty || _equal(seen, expected);
  }

  static bool _equal(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
