import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Riverpod provider for purchase operations (stub — app is free).
final purchaseServiceProvider = Provider<PurchaseService>((ref) {
  return PurchaseService();
});

/// Stub purchase service — does nothing. App is completely free.
class PurchaseService {
  Future<void> init() async {}
  bool get isAvailable => false;
}
