/// `RILL_SEMANTICS_PROBE=1` — task 32 §1: which step of a session makes the
/// engine's accessibility bridge log `Failed to update ui::AXTree`.
///
/// The same family as `RILL_CONTROLS_PROBE`, and for the same reason: the error
/// comes from the engine's Windows bridge, which `flutter test` does not have.
/// It runs the real app with semantics forced on, drives a fixed script with
/// synthesised pointer events, and writes one `probe: STEP …` marker per step to
/// stderr. The launcher interleaves those with the engine's own lines in
/// `%LOCALAPPDATA%\rill\logs`, so the errors between two markers belong to the
/// step the first one opened: count the lines matching
/// `Failed to update ui::AXTree` between consecutive markers.
///
/// `RILL_SEMANTICS_PROBE_VIDEO=<id>` picks the video (default one with a busy
/// comments section). The semantics tree is dumped to
/// `%TEMP%\rill-semantics-after-open.txt` once the video's page has settled.
/// Unset, this costs one environment lookup at startup. `architecture.md` F51
/// has what it found; re-run it on every Flutter pin bump.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'player/settings_menu.dart' show SettingsPage, playerMenuProvider;
import 'player/view_mode.dart';
import 'player_shell.dart';
import 'queue_controller.dart';
import '../domain/youtube_link.dart';

void runSemanticsProbe(ProviderContainer container) {
  if (Platform.environment['RILL_SEMANTICS_PROBE'] != '1') return;
  SemanticsBinding.instance.ensureSemantics();
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_probe(container)));
}

/// Whether the dump runs: `RILL_SEMANTICS_DUMP=1` asks for it, `=0` refuses it, and with neither it is
/// **on in a dev build** (no `RILL_VERSION` baked in) — the `AXTree` hunt of October 2026 needs the
/// node log from every session the developer runs, and a released build, which has a version, never
/// forces semantics on or writes files unasked. Remove the default on 2026-11-28 (`todo.md` 87).
bool _dumpWanted() {
  final asked = Platform.environment['RILL_SEMANTICS_DUMP'];
  if (asked == '1') return true;
  if (asked == '0') return false;
  return const String.fromEnvironment('RILL_VERSION').isEmpty;
}

/// `RILL_SEMANTICS_DUMP=1`: turns semantics on and writes the whole semantics tree, with its
/// node ids, to `%TEMP%\rill-semantics-ring-<n>.txt` once a second, oldest overwritten. It keeps
/// the last 300 seconds (`RILL_SEMANTICS_DUMP_KEEP=<seconds>` to change it; about 10 KB a file).
///
/// The accessibility bridge's errors name a node id and nothing else; the id is only
/// meaningful against a tree from the same run. Reproduce the error, then read the files
/// written around the moment it appeared (their timestamps say which). Nothing is logged per
/// dump: a line a second would fill the 10 MB log and push the error's start out of it.
void runSemanticsDump() {
  if (!_dumpWanted()) return;
  SemanticsBinding.instance.ensureSemantics();
  final keep = int.tryParse(Platform.environment['RILL_SEMANTICS_DUMP_KEEP'] ?? '') ?? 300;
  _watchNodeChanges();
  var n = 0;
  Timer.periodic(const Duration(seconds: 1), (_) {
    try {
      _dumpTree('ring-${n++ % keep}', quiet: true);
    } on Object catch (error) {
      stderr.writeln('semantics dump failed: $error');
    }
  });
}

/// Every semantics node that appears or disappears, frame by frame, to
/// `%TEMP%\rill-semantics-changes.txt` (the last ~4 MB). The once-a-second tree dumps cannot
/// see a node that lives for a few frames — a tooltip, a menu — and an `AXTree` error can name
/// exactly such a node; this names it, with its label, its parent and the time.
void _watchNodeChanges() {
  final path = '${Directory.systemTemp.path}\\rill-semantics-changes.txt';
  final file = File(path);
  file.writeAsStringSync('');
  var known = <int, String>{};
  var written = 0;
  void frame(Duration _) {
    WidgetsBinding.instance.addPostFrameCallback(frame);
    final root = RendererBinding.instance.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
    if (root == null) return;
    final now = <int, String>{};
    void walk(SemanticsNode node, SemanticsNode? parent) {
      final data = node.getSemanticsData();
      final label = data.label.replaceAll('\n', ' / ');
      final tip = data.tooltip.isEmpty ? '' : ' tooltip="${data.tooltip}"';
      final r = node.rect;
      now[node.id] = '"$label"$tip ${r.width.round()}x${r.height.round()} parent=#${parent?.id}';
      node.visitChildren((c) {
        walk(c, node);
        return true;
      });
    }

    walk(root, null);
    final stamp = DateTime.now().toIso8601String().substring(11, 23);
    final lines = StringBuffer();
    for (final e in now.entries) {
      if (!known.containsKey(e.key)) lines.writeln('$stamp + #${e.key} ${e.value}');
    }
    for (final e in known.entries) {
      if (!now.containsKey(e.key)) lines.writeln('$stamp - #${e.key} ${e.value}');
    }
    known = now;
    if (lines.isEmpty) return;
    final text = lines.toString();
    written += text.length;
    // Start over rather than grow without end: the error is in the last few minutes.
    if (written > 4000000) {
      file.writeAsStringSync('');
      written = text.length;
    }
    file.writeAsStringSync(text, mode: FileMode.append);
  }

  WidgetsBinding.instance.addPostFrameCallback(frame);
}

void _say(String line) => stderr.writeln('probe: $line');

Future<void> _wait([int millis = 4000]) => Future<void>.delayed(Duration(milliseconds: millis));

Future<void> _step(String name, FutureOr<void> Function() body) async {
  await stderr.flush();
  _say('STEP $name');
  await body();
  await _wait();
}

int _pointer = 900;

void _tapAt(Offset position) {
  final id = _pointer++;
  final binding = GestureBinding.instance;
  binding.handlePointerEvent(PointerAddedEvent(position: position, pointer: id));
  binding.handlePointerEvent(PointerDownEvent(position: position, pointer: id));
  binding.handlePointerEvent(PointerUpEvent(position: position, pointer: id));
  binding.handlePointerEvent(PointerRemovedEvent(position: position, pointer: id));
}

/// A mouse hover — what wakes the player controls when they have auto-hidden.
void _hoverAt(Offset position) {
  final id = _pointer++;
  final binding = GestureBinding.instance;
  binding.handlePointerEvent(PointerAddedEvent(position: position, pointer: id, kind: PointerDeviceKind.mouse));
  binding.handlePointerEvent(PointerHoverEvent(position: position, pointer: id, kind: PointerDeviceKind.mouse));
  binding.handlePointerEvent(PointerHoverEvent(position: position + const Offset(5, 5), pointer: id, kind: PointerDeviceKind.mouse));
}

void _scrollAt(Offset position, double dy) {
  final id = _pointer++;
  final binding = GestureBinding.instance;
  binding.handlePointerEvent(PointerAddedEvent(position: position, pointer: id, kind: PointerDeviceKind.mouse));
  binding.handlePointerEvent(PointerScrollEvent(position: position, scrollDelta: Offset(0, dy), kind: PointerDeviceKind.mouse));
  binding.handlePointerEvent(PointerRemovedEvent(position: position, pointer: id, kind: PointerDeviceKind.mouse));
}

/// The centre of the first rendered text whose plain text matches [pattern].
Offset? _findText(RegExp pattern) => _find((widget) {
  final text = switch (widget) {
    Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText(),
    RichText(:final text) => text.toPlainText(),
    _ => null,
  };
  return text != null && pattern.hasMatch(text);
});

Offset? _find(bool Function(Widget widget) matches) {
  // The *last* match: the feed stays mounted under the watch page, and the walk
  // reaches it first.
  Offset? found;
  void visit(Element element) {
    final widget = element.widget;
    if (matches(widget)) {
      final box = element.renderObject;
      if (box is RenderBox && box.attached && box.hasSize) {
        final origin = box.localToGlobal(Offset.zero);
        found = origin + box.size.center(Offset.zero);
      }
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

/// The semantics tree as the engine is sent it, ids included, to a file — a
/// dump of a few thousand lines does not belong in the log.
void _dumpTree(String label, {bool quiet = false}) {
  final root = RendererBinding.instance.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  final path = '${Directory.systemTemp.path}\\rill-semantics-$label.txt';
  final out = StringBuffer();
  void walk(SemanticsNode node, int depth) {
    final data = node.getSemanticsData();
    final r = node.rect;
    out.writeln('${'  ' * depth}#${node.id} rect=${r.left.round()},${r.top.round()} ${r.width.round()}x${r.height.round()} '
        'label="${data.label.replaceAll('\n', ' / ')}" value="${data.value}" tooltip="${data.tooltip}" '
        'hidden=${node.isInvisible} merged=${node.isMergedIntoParent} '
        'actions=${data.actions}${data.flagsCollection.isFocused == Tristate.isTrue ? ' FOCUSED' : ''}');
    node.visitChildren((child) {
      walk(child, depth + 1);
      return true;
    });
  }

  if (root == null) {
    out.writeln('no semantics root');
  } else {
    walk(root, 0);
  }
  File(path).writeAsStringSync(out.toString());
  if (!quiet) _say('tree dumped to $path');
}

Future<void> _probe(ProviderContainer container) async {
  try {
    final videoId = Platform.environment['RILL_SEMANTICS_PROBE_VIDEO']?.trim().isNotEmpty == true
        ? Platform.environment['RILL_SEMANTICS_PROBE_VIDEO']!.trim()
        : 'dQw4w9WgXcQ';
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    _say('semantics on, window=$size');

    await _wait(6000);
    await _step('1-feed', () {});

    await _step('2-open-video', () => openWatchIn(container, placeholderVideoItem(videoId)));
    // Give the video and its metadata longer than a settle: the log shows the
    // worst bursts follow the page filling in.
    await _wait(6000);
    _dumpTree('after-open');

    await _step('3-theatre-on', () => container.read(playerViewProvider.notifier).toggleTheatre());
    await _step('3b-theatre-off', () => container.read(playerViewProvider.notifier).toggleTheatre());

    // Let the controls auto-hide, then wake them with a hover over the player.
    await _step('3c-controls-hidden', () {});
    await _wait(4000);
    final overPlayer = Offset(size.width * 0.35, size.height * 0.35);
    await _step('3d-controls-wake', () => _hoverAt(overPlayer));

    // The settings menu: it fades in from opacity 0, changes page through a
    // `FadeTransition`, and the style page is full of Sliders.
    //
    // Driven through `playerMenuProvider`, which is what the gear and the rows
    // call, rather than through taps: a tap on a row needs the controls awake
    // and the right row mounted, and what is being measured is the menu's fades.
    final menu = container.read(playerMenuProvider.notifier);
    await _step('3e-menu-open', () async {
      _hoverAt(overPlayer);
      await _wait(800);
      menu.open();
    });
    _say('menu open=${container.read(playerMenuProvider).open}');
    await _step('3f-menu-more-options', () => menu.go(SettingsPage.moreOptions));
    await _step('3g-menu-caption-style', () => menu.go(SettingsPage.captionStyle));
    await _step('3h-menu-close', menu.close);

    await _step('4-scroll-comments', () {
      for (var i = 0; i < 6; i++) {
        _scrollAt(Offset(size.width * 0.35, size.height * 0.6), 600);
      }
    });

    await _step('5-expand-thread', () {
      final target = _findText(RegExp(r'^\d+ repl(y|ies)$'));
      _say('replies toggle at $target');
      if (target != null) _tapAt(target);
    });

    await _step('6-open-queue', () {
      // The embedded queue panel mounts once there is more than one item.
      final queue = container.read(queueProvider.notifier);
      queue.addToQueue(placeholderVideoItem('9bZkp7q19f0'));
      queue.addToQueue(placeholderVideoItem('jNQXAC9IVRw'));
    });

    await _step('7-back-to-feed', () => toMiniPlayerIn(container));
    await _step('8-end', () {});

    _say('done');
  } on Object catch (error, stack) {
    _say('FAILED $error\n$stack');
    exit(1);
  }
  await stderr.flush();
  exit(0);
}
