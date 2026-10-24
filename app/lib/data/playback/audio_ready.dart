import 'dart:async';

/// Waits for the audio decoder to report a format, for at most [timeout].
///
/// **Subscribes before it returns**, which is the point of it being a function and
/// not a `firstWhere` at the call site: the audio track is attached by a command
/// whose first effect can land before the caller's next line, and a listener
/// added afterwards would wait for an event that had already gone by.
///
/// [decoded] emits `true` once mpv has audio params for the current file
/// (`audio-params` with a sample rate), and anything else is ignored. The future
/// answers `false` on [timeout] rather than throwing: a broken audio URL must not
/// hold the picture back, so the caller plays without it. `architecture.md` §2.4.
({Future<bool> ready, void Function() cancel}) listenForAudio(Stream<bool> decoded, Duration timeout) {
  final done = Completer<bool>();
  late final StreamSubscription<bool> subscription;
  Timer? timer;

  void finish(bool value) {
    timer?.cancel();
    unawaited(subscription.cancel());
    if (!done.isCompleted) done.complete(value);
  }

  subscription = decoded.listen(
    (value) {
      if (value) finish(true);
    },
    onError: (Object _) => finish(false),
    onDone: () => finish(false),
  );
  timer = Timer(timeout, () => finish(false));
  return (ready: done.future, cancel: () => finish(false));
}
