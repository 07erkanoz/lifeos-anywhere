import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/logger.dart';

/// HTTP header that carries the per-pair secret on every request between
/// two paired devices.
const String kPairTokenHeader = 'X-AnyWhere-Token';

/// HTTP header with the sender's protocol version. Its presence tells the
/// receiver that the sender can store a pairing token (protocol >= 1.1).
const String kProtocolHeader = 'X-AnyWhere-Protocol';

/// Capability flag advertised in the Device JSON (`capabilities` list).
const String kPairingCapability = 'pairing-token';

/// A device this device has been paired with.
///
/// Pairing is mutual: the same [token] is stored on both sides, so either
/// device can send to the other without asking again.
///
/// A device paired with an old (1.0.x) app version cannot store a token.
/// Such an entry has `token == null` and is trusted by device id together
/// with its last known IP address ([lastIp]) — this is weaker, since anyone
/// on the network who takes over that IP is trusted too.
class TrustedDevice {
  const TrustedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.token,
    required this.pairedAt,
    this.lastIp = '',
  });

  final String id;
  final String name;
  final String platform;
  final String? token;
  final DateTime pairedAt;
  final String lastIp;

  /// Trusted by device id + IP only (old peer without token support).
  bool get isLegacy => token == null || token!.isEmpty;

  factory TrustedDevice.fromJson(Map<String, dynamic> json) {
    return TrustedDevice(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      token: json['token'] as String?,
      pairedAt:
          DateTime.tryParse(json['pairedAt'] as String? ?? '') ??
          DateTime.now(),
      lastIp: json['lastIp'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    if (token != null) 'token': token,
    'pairedAt': pairedAt.toIso8601String(),
    'lastIp': lastIp,
  };

  TrustedDevice copyWith({
    String? name,
    String? platform,
    String? token,
    String? lastIp,
  }) {
    return TrustedDevice(
      id: id,
      name: name ?? this.name,
      platform: platform ?? this.platform,
      token: token ?? this.token,
      pairedAt: pairedAt,
      lastIp: lastIp ?? this.lastIp,
    );
  }
}

/// Persistent list of paired (trusted) devices, plus the short-lived QR
/// pairing codes and the Web Portal key.
///
/// Used by both the server (to verify incoming requests) and the clients
/// (to attach the token to outgoing requests).
class TrustStore extends ChangeNotifier {
  TrustStore(this._prefs) {
    _load();
  }

  static final _log = AppLogger('TrustStore');
  static const _prefKey = 'trusted_devices_v1';
  static const _portalKeyPref = 'portal_key_v1';

  /// How long a QR pairing code stays valid.
  static const Duration pairCodeLifetime = Duration(minutes: 10);

  final SharedPreferences _prefs;
  final Map<String, TrustedDevice> _devices = {};
  final Map<String, DateTime> _pairCodes = {};
  final Random _random = Random.secure();

  /// All paired devices, most recently paired first.
  List<TrustedDevice> get devices {
    final list = _devices.values.toList()
      ..sort((a, b) => b.pairedAt.compareTo(a.pairedAt));
    return list;
  }

  TrustedDevice? byId(String id) => _devices[id];

  bool isTrusted(String id) => _devices.containsKey(id);

  /// Token to attach when talking to [peerId], or `null` when not paired
  /// (or paired only in legacy mode).
  String? tokenFor(String peerId) {
    final d = _devices[peerId];
    return d == null || d.isLegacy ? null : d.token;
  }

  /// Headers every outgoing request to [peerId] should carry.
  Map<String, String> authHeaders(String? peerId) {
    final token = peerId == null ? null : tokenFor(peerId);
    return {
      kProtocolHeader: AppConstants.protocolVersion,
      kPairTokenHeader: ?token,
    };
  }

  /// Finds the device that owns [token] (constant-time comparison).
  TrustedDevice? byToken(String? token) {
    if (token == null || token.isEmpty) return null;
    for (final d in _devices.values) {
      final t = d.token;
      if (t != null && _constantTimeEquals(t, token)) return d;
    }
    return null;
  }

  /// Finds a legacy (token-less) entry whose last known IP is [ip].
  TrustedDevice? legacyByIp(String ip) {
    if (ip.isEmpty) return null;
    for (final d in _devices.values) {
      if (d.isLegacy && d.lastIp == ip) return d;
    }
    return null;
  }

  /// Creates a fresh random 32-byte secret, base64url encoded.
  String newToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Stores (or replaces) a trusted device. Pass `token: null` to trust an
  /// old peer by id + IP only.
  Future<TrustedDevice> trust({
    required String id,
    required String name,
    required String platform,
    required String? token,
    String ip = '',
  }) async {
    final existing = _devices[id];
    final device = TrustedDevice(
      id: id,
      name: name.isNotEmpty ? name : (existing?.name ?? id),
      platform: platform.isNotEmpty ? platform : (existing?.platform ?? ''),
      token: token,
      pairedAt: existing?.pairedAt ?? DateTime.now(),
      lastIp: ip.isNotEmpty ? ip : (existing?.lastIp ?? ''),
    );
    _devices[id] = device;
    await _save();
    notifyListeners();
    return device;
  }

  /// Updates the last known IP / name of a trusted device (no-op otherwise).
  void touch(String id, {String? ip, String? name}) {
    final d = _devices[id];
    if (d == null) return;
    final changedIp = ip != null && ip.isNotEmpty && ip != d.lastIp;
    final changedName = name != null && name.isNotEmpty && name != d.name;
    if (!changedIp && !changedName) return;
    _devices[id] = d.copyWith(
      lastIp: changedIp ? ip : null,
      name: changedName ? name : null,
    );
    _save();
    notifyListeners();
  }

  /// Removes the pairing with [id]. The device will be asked again the next
  /// time it contacts us.
  Future<void> remove(String id) async {
    if (_devices.remove(id) == null) return;
    await _save();
    notifyListeners();
  }

  // ── QR pairing codes ────────────────────────────────────────────────

  /// Issues a one-time pairing code to embed in this device's QR code.
  /// Whoever scans it is trusted without a prompt (the user showed the QR).
  String issuePairCode() {
    _pairCodes.removeWhere(
      (_, issued) => DateTime.now().difference(issued) > pairCodeLifetime,
    );
    final code = newToken().substring(0, 22);
    _pairCodes[code] = DateTime.now();
    return code;
  }

  /// Consumes [code] if it is a valid, unexpired QR pairing code.
  bool consumePairCode(String? code) {
    if (code == null || code.isEmpty) return false;
    String? match;
    for (final c in _pairCodes.keys) {
      if (_constantTimeEquals(c, code)) match = c;
    }
    if (match == null) return false;
    final issued = _pairCodes.remove(match)!;
    return DateTime.now().difference(issued) <= pairCodeLifetime;
  }

  // ── Web Portal key ──────────────────────────────────────────────────

  /// Secret that a browser must present (via the portal URL, then a cookie)
  /// to use the Web Portal. It is only shown on this device's screen.
  String get portalKey {
    var key = _prefs.getString(_portalKeyPref);
    if (key == null || key.isEmpty) {
      key = newToken().substring(0, 22);
      _prefs.setString(_portalKeyPref, key);
    }
    return key;
  }

  bool checkPortalKey(String? key) =>
      key != null && key.isNotEmpty && _constantTimeEquals(key, portalKey);

  // ── Persistence ─────────────────────────────────────────────────────

  void _load() {
    final raw = _prefs.getString(_prefKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final e in list) {
        final d = TrustedDevice.fromJson(e as Map<String, dynamic>);
        _devices[d.id] = d;
      }
    } catch (e) {
      _log.warning('Could not read trusted devices: $e');
    }
  }

  Future<void> _save() async {
    final raw = jsonEncode(_devices.values.map((d) => d.toJson()).toList());
    await _prefs.setString(_prefKey, raw);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  @visibleForTesting
  bool get hasPendingPairCodes => _pairCodes.isNotEmpty;
}
