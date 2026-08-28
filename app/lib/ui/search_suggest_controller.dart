import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../data/rpc/client.dart';

/// Autocomplete state for the topbar search field (Task 20 §4).
///
/// The first real exercise of `$cancel` and the generation guard under actual
/// typing load — every prior use (the feed's chip switch) fires at most a few
/// times a minute. Sustained typing fires it per keystroke.
class SearchSuggestState {
  const SearchSuggestState({
    this.query = '',
    this.suggestions = const [],
    this.isOpen = false,
  });

  final String query;
  final List<String> suggestions;
  final bool isOpen;

  SearchSuggestState copyWith({String? query, List<String>? suggestions, bool? isOpen}) {
    return SearchSuggestState(
      query: query ?? this.query,
      suggestions: suggestions ?? this.suggestions,
      isOpen: isOpen ?? this.isOpen,
    );
  }
}

class SearchSuggestController extends Notifier<SearchSuggestState> {
  /// 200ms — the middle of the 150–250ms range Task 20 §4 asks for. Long
  /// enough that sustained typing (measured against 8 chars/s, i.e. 125ms
  /// between keystrokes) collapses to a handful of requests rather than one
  /// per keystroke; short enough that a pause to read the dropdown does not
  /// read as sluggish.
  static const Duration debounce = Duration(milliseconds: 200);

  /// Bumped by every request. Mirrors `FeedController`'s guard: `$cancel` is
  /// best-effort — the sidecar can already be mid-write when the abort signal
  /// arrives — so a response landing for a superseded request is dropped here
  /// too rather than trusted to never arrive.
  int _generation = 0;
  int? _inFlight;
  Timer? _debounceTimer;

  /// Instrumentation for the sustained-typing test — how many `search.suggest`
  /// requests actually reached the wire, and how many were cancelled before
  /// answering. Not read by the app.
  @visibleForTesting
  int requestsIssued = 0;
  @visibleForTesting
  int requestsCancelled = 0;

  @override
  SearchSuggestState build() {
    ref.onDispose(() {
      _debounceTimer?.cancel();
      _cancelInFlight();
    });
    return const SearchSuggestState();
  }

  /// Called on every keystroke. Debounced: only the last call in a burst
  /// shorter than [debounce] actually issues a request.
  void onTextChanged(String text) {
    state = state.copyWith(query: text, isOpen: text.trim().isNotEmpty);
    _debounceTimer?.cancel();

    if (text.trim().isEmpty) {
      _cancelInFlight();
      _generation++; // any in-flight answer is now stale too
      state = state.copyWith(suggestions: const []);
      return;
    }

    _debounceTimer = Timer(debounce, () => _fetch(text));
  }

  Future<void> _fetch(String query) async {
    _cancelInFlight();
    final generation = ++_generation;
    requestsIssued++;

    final request = RpcClient.instance.callCancelable('search.suggest', {'q': query});
    _inFlight = request.id;

    try {
      final response = await request.response;
      if (generation != _generation) return; // superseded — drop, never render
      _inFlight = null;
      final raw = response['suggestions'] as List<dynamic>? ?? [];
      state = state.copyWith(suggestions: raw.whereType<String>().toList());
    } on RpcException catch (_) {
      // A suggest failure is not worth surfacing to the user — the dropdown
      // just stays empty, and typing Enter still searches directly.
      if (generation != _generation) return;
      _inFlight = null;
    } catch (_) {
      if (generation != _generation) return;
      _inFlight = null;
    }
  }

  void _cancelInFlight() {
    final previous = _inFlight;
    if (previous == null) return;
    RpcClient.instance.cancel(previous);
    requestsCancelled++;
    _inFlight = null;
  }

  /// Escape or blur.
  void close() {
    _debounceTimer?.cancel();
    _cancelInFlight();
    state = state.copyWith(isOpen: false);
  }
}

final searchSuggestProvider =
    NotifierProvider<SearchSuggestController, SearchSuggestState>(SearchSuggestController.new);
