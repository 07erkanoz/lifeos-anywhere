import 'package:flutter/material.dart';

import 'package:anyware/core/licensing/feature_gate.dart';

/// No-op — all features are free. Kept for API compatibility.
Future<void> showProUpgradeDialog(
  BuildContext context,
  ProFeature feature,
  String locale,
) async {
  // Nothing to show — all features are unlocked.
}
