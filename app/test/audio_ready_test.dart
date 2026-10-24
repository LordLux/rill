import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/playback/audio_ready.dart';

void main() {
  test('answers true when the decoder reports a format', () async {
    final decoded = StreamController<bool>();
    final listening = listenForAudio(decoded.stream, const Duration(seconds: 5));
    decoded.add(false);
    decoded.add(true);
    expect(await listening.ready, isTrue);
    expect(decoded.hasListener, isFalse, reason: 'the subscription is released once it has an answer');
    await decoded.close();
  });

  test('an event that fires before the caller awaits is not lost', () async {
    final decoded = StreamController<bool>();
    final listening = listenForAudio(decoded.stream, const Duration(seconds: 5));
    decoded.add(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await listening.ready, isTrue);
    await decoded.close();
  });

  test('answers false at the bound instead of holding the picture for a dead audio URL', () async {
    final decoded = StreamController<bool>();
    final listening = listenForAudio(decoded.stream, const Duration(milliseconds: 30));
    expect(await listening.ready, isFalse);
    expect(decoded.hasListener, isFalse);
    await decoded.close();
  });

  test('answers false when the stream ends or errors without a format', () async {
    final ended = StreamController<bool>();
    final a = listenForAudio(ended.stream, const Duration(seconds: 5));
    await ended.close();
    expect(await a.ready, isFalse);

    final failed = StreamController<bool>();
    final b = listenForAudio(failed.stream, const Duration(seconds: 5));
    failed.addError(StateError('mpv went away'));
    expect(await b.ready, isFalse);
    await failed.close();
  });

  test('cancel releases the subscription and answers false', () async {
    final decoded = StreamController<bool>();
    final listening = listenForAudio(decoded.stream, const Duration(seconds: 5));
    listening.cancel();
    expect(await listening.ready, isFalse);
    expect(decoded.hasListener, isFalse);
    await decoded.close();
  });
}
