import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/features/pairing/data/pairing_client.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/domain/pairing_request.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';

/// Paired (trusted) devices, persisted in SharedPreferences.
final trustStoreProvider = ChangeNotifierProvider<TrustStore>((ref) {
  return TrustStore(ref.watch(sharedPreferencesProvider));
});

final pairingClientProvider = Provider<PairingClient>((ref) {
  return PairingClient(ref.watch(trustStoreProvider));
});

/// A pairing prompt waiting for the user's answer.
class PendingPairingPrompt {
  PendingPairingPrompt(this.request);

  final PairingRequest request;
  final Completer<PairingDecision> _completer = Completer<PairingDecision>();

  bool get isResolved => _completer.isCompleted;
}

/// Queue of pairing prompts. The app shows the first one as a dialog; the
/// file server waits on [ask] for the answer.
class PairingPromptNotifier extends StateNotifier<List<PendingPairingPrompt>> {
  PairingPromptNotifier() : super(const []);

  /// How long a prompt waits before it counts as "rejected".
  static const Duration timeout = Duration(seconds: 60);

  Future<PairingDecision> ask(PairingRequest request) {
    final prompt = PendingPairingPrompt(request);
    state = [...state, prompt];
    return prompt._completer.future.timeout(
      timeout,
      onTimeout: () {
        resolve(prompt, PairingDecision.reject);
        return PairingDecision.reject;
      },
    );
  }

  void resolve(PendingPairingPrompt prompt, PairingDecision decision) {
    if (!prompt._completer.isCompleted) prompt._completer.complete(decision);
    state = state.where((p) => !identical(p, prompt)).toList();
  }
}

final pairingPromptProvider =
    StateNotifierProvider<PairingPromptNotifier, List<PendingPairingPrompt>>(
      (ref) => PairingPromptNotifier(),
    );
