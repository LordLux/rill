/// `RILL_FOCUS_PROBE=feed|watch|subscriptions` — Task 32 follow-up: walk Tab through the
/// real app and log every stop.
///
/// A widget test sees the stops the fake data produces; this sees the real feed,
/// the real comments and the real queue. Each line is
/// `FOCUS n: name | widget chain | rect [OFFSCREEN]` on stderr, so a "ghost" stop (nothing visibly
/// selected) shows up as a name that is only a widget chain, and a stop that
/// Tab reached without scrolling it into view shows up as OFFSCREEN. Reverse
/// with `RILL_FOCUS_PROBE_REVERSE=1`; `RILL_FOCUS_PROBE_STOPS=<n>` (default 90);
/// `RILL_FOCUS_PROBE_VIDEO=<id>` for the watch page.
///
/// Unset, this costs one environment lookup at startup.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'player/controls.dart';
import 'player/view_mode.dart';
import '../domain/youtube_link.dart';
import 'player_shell.dart';
import 'queue_controller.dart';
void runFocusProbe(ProviderContainer container) {
  final mode = Platform.environment['RILL_FOCUS_PROBE'];
  if (mode == null || mode.isEmpty) return;
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_probe(container, mode)));
}

void _say(String line) => stderr.writeln('probe: $line');

Future<void> _wait([int millis = 400]) => Future<void>.delayed(Duration(milliseconds: millis));

/// One line naming a focus stop: its tooltip, string key or text, and the widgets
/// above it. `NAMELESS` is a stop with nothing to say what it is — a ghost.
String describeFocusNode(FocusNode node) {
  final context = node.context;
  if (context == null) return 'detached';
  String? name;
  void check(Widget widget) {
    if (name != null) return;
    if (widget is EditableText) {
      name = 'field';
    } else if (widget is Tooltip && widget.message != null) {
      name = 'tooltip:${widget.message}';
    } else if (widget.key is ValueKey<String>) {
      name = 'key:${(widget.key! as ValueKey<String>).value}';
    }
  }

  check(context.widget);
  final chain = <String>[context.widget.runtimeType.toString()];
  context.visitAncestorElements((element) {
    check(element.widget);
    if (chain.length < 6) chain.add(element.widget.runtimeType.toString());
    return name == null || chain.length < 6;
  });
  String? text;
  void visit(Element element) {
    final widget = element.widget;
    if (text == null && widget is Text && widget.data != null) text = widget.data;
    if (text == null && widget is Icon && widget.semanticLabel != null) text = 'icon:${widget.semanticLabel}';
    if (text == null) element.visitChildren(visit);
  }

  (context as Element).visitChildren(visit);
  return '${name ?? 'NAMELESS'}${text == null ? '' : ' "$text"'} | ${chain.join('<')}';
}

Future<void> _probe(ProviderContainer container, String mode) async {
  try {
    final stops = int.tryParse(Platform.environment['RILL_FOCUS_PROBE_STOPS'] ?? '') ?? 90;
    final reverse = Platform.environment['RILL_FOCUS_PROBE_REVERSE'] == '1';
    final dwell = int.tryParse(Platform.environment['RILL_FOCUS_PROBE_DWELL'] ?? '') ?? 0;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final window = view.physicalSize / view.devicePixelRatio;
    // Semantics on, as a screen reader would have them: that is what fails.
    SemanticsBinding.instance.ensureSemantics();
    await _wait(6000);
    // `RILL_FOCUS_PROBE_SIZE=1600x900`: the watch page lays out differently by width.
    final size = (Platform.environment['RILL_FOCUS_PROBE_SIZE'] ?? '').split('x').map(double.tryParse).toList();
    if (size.length == 2 && size[0] != null && size[1] != null) {
      appWindow.size = Size(size[0]!, size[1]!);
      await _wait(2000);
    }

    if (mode == 'scrollchange') {
      // The watch page scrolled down into its comments, focus somewhere inside the page, and the
      // video changes: new comments, new related, the old nodes going away under a focused one.
      final binding = GestureBinding.instance;
      const device = 31;
      binding.handlePointerEvent(const PointerAddedEvent(position: Offset(600, 500), kind: PointerDeviceKind.mouse, device: device));
      final videos = ['dQw4w9WgXcQ', '9bZkp7q19f0', 'kJQP7kiw5Fk', '3JZ_D3ELwOQ'];
      var current = 0;
      openWatchIn(container, placeholderVideoItem(videos[current]));
      await _wait(10000);
      for (var cycle = 0; cycle < 8; cycle++) {
        for (var s = 0; s < 3; s++) {
          binding.handlePointerEvent(PointerScrollEvent(position: const Offset(600, 500), scrollDelta: const Offset(0, 400), kind: PointerDeviceKind.mouse, device: device));
          await _wait(500);
        }
        final tabs = 8 + cycle * 7;
        for (var i = 0; i < tabs; i++) {
          FocusManager.instance.primaryFocus?.nextFocus();
          await _wait(40);
        }
        current = (current + 1) % videos.length;
        _say('SCROLLCHANGE $cycle: focus=${FocusManager.instance.primaryFocus?.debugLabel ?? FocusManager.instance.primaryFocus.runtimeType}; opening ${videos[current]}');
        openWatchIn(container, placeholderVideoItem(videos[current]));
        await _wait(7000);
      }
      _say('SCROLLCHANGE done');
      await stderr.flush();
      return;
    }

    if (mode == 'monkey') {
      // A screen reader's hands: pick a random tappable node from the semantics tree and press it,
      // scroll, Tab, change video — and log each step, so that if an AXTree error appears the
      // steps just before it are in the same log. Only labels on a short allow-list are pressed:
      // nothing that changes the account (like, subscribe, vote, delete) and nothing that leaves the app.
      final random = math.Random(int.tryParse(Platform.environment['RILL_MONKEY_SEED'] ?? '') ?? 7);
      final steps = int.tryParse(Platform.environment['RILL_MONKEY_STEPS'] ?? '') ?? 150;
      final safe = RegExp(
        r'^(Show \d+ repl|Hide \d+ repl|Top$|Newest$|Show more|Show less|Mute|Unmute|Pause|Play$|Theatre mode|Fullscreen|Exit fullscreen|Miniplayer|Home|Subscriptions|Back$|Toggle menu|Share$|Close|Save to playlist|More actions|Captions|Settings|Quality|Next video|Previous video|Remove from queue|Video,|Music Video,|Playlist,|Mix|Short,|Live,|Station,)',
      );
      final binding = GestureBinding.instance;
      const device = 21;
      binding.handlePointerEvent(const PointerAddedEvent(position: Offset(400, 400), kind: PointerDeviceKind.mouse, device: device));
      final videos = ['dQw4w9WgXcQ', '9bZkp7q19f0', 'kJQP7kiw5Fk', '3JZ_D3ELwOQ'];
      openWatchIn(container, placeholderVideoItem(videos[0]));
      for (final v in videos.skip(1)) {
        container.read(queueProvider.notifier).addToQueue(placeholderVideoItem(v));
      }
      await _wait(10000);

      List<(int, String)> tappable() {
        final owner = RendererBinding.instance.renderViews.first.owner?.semanticsOwner;
        final out = <(int, String)>[];
        void walk(SemanticsNode node) {
          final data = node.getSemanticsData();
          if (data.hasAction(SemanticsAction.tap) && safe.hasMatch(data.label)) out.add((node.id, data.label));
          node.visitChildren((c) {
            walk(c);
            return true;
          });
        }

        final root = owner?.rootSemanticsNode;
        if (root != null) walk(root);
        return out;
      }

      var n = 0;
      for (; n < steps; n++) {
        final roll = random.nextInt(100);
        if (roll < 55) {
          final nodes = tappable();
          if (nodes.isEmpty) {
            _say('MONKEY $n: nothing to press');
          } else {
            final pick = nodes[random.nextInt(nodes.length)];
            _say('MONKEY $n: tap #${pick.$1} "${pick.$2.replaceAll('\n', ' / ')}"');
            RendererBinding.instance.renderViews.first.owner!.semanticsOwner!.performAction(pick.$1, SemanticsAction.tap);
          }
        } else if (roll < 75) {
          final dy = (random.nextBool() ? 1 : -1) * (100.0 + random.nextInt(500));
          final at = Offset(300.0 + random.nextInt(900), 200.0 + random.nextInt(500));
          _say('MONKEY $n: scroll $dy at $at');
          binding.handlePointerEvent(PointerScrollEvent(position: at, scrollDelta: Offset(0, dy), kind: PointerDeviceKind.mouse, device: device));
        } else if (roll < 90) {
          final k = 1 + random.nextInt(6);
          _say('MONKEY $n: tab x$k');
          for (var i = 0; i < k; i++) {
            FocusManager.instance.primaryFocus?.nextFocus();
            await _wait(60);
          }
        } else if (roll < 96) {
          final v = videos[random.nextInt(videos.length)];
          _say('MONKEY $n: open video $v');
          openWatchIn(container, placeholderVideoItem(v));
        } else {
          _say('MONKEY $n: Escape');
          HardwareKeyboard.instance.handleKeyEvent(KeyDownEvent(physicalKey: PhysicalKeyboardKey.escape, logicalKey: LogicalKeyboardKey.escape, timeStamp: Duration.zero));
          HardwareKeyboard.instance.handleKeyEvent(KeyUpEvent(physicalKey: PhysicalKeyboardKey.escape, logicalKey: LogicalKeyboardKey.escape, timeStamp: Duration.zero));
        }
        await _wait(700 + random.nextInt(900));
      }
      _say('MONKEY done after $n steps');
      await stderr.flush();
      return;
    }

    if (mode == 'keystate') {
      // The Alt+Tab case: Alt goes down in this window and its release goes elsewhere. Does
      // the platform answer "what is down", and does coming back clear the stale Alt?
      HardwareKeyboard.instance.handleKeyEvent(KeyDownEvent(physicalKey: PhysicalKeyboardKey.altLeft, logicalKey: LogicalKeyboardKey.altLeft, timeStamp: Duration.zero));
      _say('KEYSTATE alt held in Flutter: ${HardwareKeyboard.instance.isAltPressed}');
      try {
        final state = await SystemChannels.keyboard.invokeMapMethod<int, int>('getKeyboardState');
        _say('KEYSTATE platform answers: ${state == null ? 'null' : '${state.length} keys down'}');
      } on Object catch (error) {
        _say('KEYSTATE platform query failed: $error');
      }
      WidgetsBinding.instance.handleViewFocusChanged(const ViewFocusEvent(viewId: 0, state: ViewFocusState.focused, direction: ViewFocusDirection.undefined));
      await _wait(500);
      _say('KEYSTATE after the window got the keyboard back: alt held = ${HardwareKeyboard.instance.isAltPressed}');
      _say('done');
      await stderr.flush();
      return;
    }

    if (mode == 'videochange') {
      // Keyboard on a player control, then the video changes (next in the queue, a new video):
      // do shortcuts and Tab still work, and is focus still on something that exists?
      openWatchIn(container, placeholderVideoItem('dQw4w9WgXcQ'));
      container.read(queueProvider.notifier).addToQueue(placeholderVideoItem('9bZkp7q19f0'));
      container.read(queueProvider.notifier).addToQueue(placeholderVideoItem('kJQP7kiw5Fk'));
      await _wait(12000);

      void key(LogicalKeyboardKey logical, PhysicalKeyboardKey physical, {bool shift = false}) {
        if (shift) {
          HardwareKeyboard.instance.handleKeyEvent(KeyDownEvent(physicalKey: PhysicalKeyboardKey.shiftLeft, logicalKey: LogicalKeyboardKey.shiftLeft, timeStamp: Duration.zero));
        }
        HardwareKeyboard.instance.handleKeyEvent(KeyDownEvent(physicalKey: physical, logicalKey: logical, timeStamp: Duration.zero));
        HardwareKeyboard.instance.handleKeyEvent(KeyUpEvent(physicalKey: physical, logicalKey: logical, timeStamp: Duration.zero));
        if (shift) {
          HardwareKeyboard.instance.handleKeyEvent(KeyUpEvent(physicalKey: PhysicalKeyboardKey.shiftLeft, logicalKey: LogicalKeyboardKey.shiftLeft, timeStamp: Duration.zero));
        }
      }

      String focusState() {
        final f = FocusManager.instance.primaryFocus;
        final c = f?.context;
        return 'focus=${f?.debugLabel ?? f.runtimeType} ctx=${c == null ? 'none' : (c.mounted ? 'mounted' : 'UNMOUNTED')} mode=${FocusManager.instance.highlightMode.name}';
      }

      Future<void> check(String when) async {
        final before = container.read(playerViewProvider).theatre;
        key(LogicalKeyboardKey.keyT, PhysicalKeyboardKey.keyT);
        await _wait(300);
        final after = container.read(playerViewProvider).theatre;
        _say('SHORTCUT $when: "t" ${before != after ? 'WORKED' : 'DID NOTHING'}; ${focusState()}');
        if (after != before) container.read(playerViewProvider.notifier).toggleTheatre();
        key(LogicalKeyboardKey.tab, PhysicalKeyboardKey.tab);
        await _wait(300);
        _say('TAB $when: ${focusState()}');
      }

      // Walk Tab onto the player's controls first.
      for (var i = 0; i < 16; i++) {
        key(LogicalKeyboardKey.tab, PhysicalKeyboardKey.tab);
        await _wait(150);
      }
      _say('KEYBOARD on a control: ${focusState()}');
      await check('before');

      for (final how in ['Shift+N', 'Shift+N', 'a new video']) {
        if (how == 'Shift+N') {
          key(LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN, shift: true);
        } else {
          openWatchIn(container, placeholderVideoItem('3JZ_D3ELwOQ'));
        }
        await _wait(9000);
        await check('after $how');
      }
      _say('done');
      await stderr.flush();
      return;
    }

    if (mode == 'controlhover') {
      // Rest the pointer on each player control until its tooltip is up.
      final binding = GestureBinding.instance;
      const device = 11;
      binding.handlePointerEvent(const PointerAddedEvent(position: Offset(5, 5), kind: PointerDeviceKind.mouse, device: device));
      openWatchIn(container, placeholderVideoItem('dQw4w9WgXcQ'));
      await _wait(12000);
      // `RILL_FOCUS_PROBE_FULLSCREEN=1`: go fullscreen first, and come back at the end.
      final fullscreen = Platform.environment['RILL_FOCUS_PROBE_FULLSCREEN'] == '1';
      if (fullscreen) {
        container.read(playerViewProvider.notifier).setFullscreen(true);
        await _wait(5000);
        _say('FULLSCREEN on');
      }
      Offset? centerOf(Key key) {
        Offset? found;
        void visit(Element element) {
          if (found != null) return;
          if (element.widget.key == key) {
            final box = element.renderObject;
            if (box is RenderBox && box.attached) found = box.localToGlobal(box.size.center(Offset.zero));
            return;
          }
          element.visitChildren(visit);
        }

        WidgetsBinding.instance.rootElement?.visitChildren(visit);
        return found;
      }

      for (final key in [playerPlayPauseKey, playerMuteKey, playerCaptionsKey, playerMiniPlayerKey, playerTheatreKey, playerFullscreenKey]) {
        // Wake the controls first (they auto-hide), then settle on the button.
        binding.handlePointerEvent(PointerHoverEvent(position: const Offset(600, 300), kind: PointerDeviceKind.mouse, device: device));
        await _wait(300);
        binding.handlePointerEvent(PointerHoverEvent(position: const Offset(640, 320), kind: PointerDeviceKind.mouse, device: device));
        await _wait(300);
        final at = centerOf(key);
        _say('HOVER control $key at $at');
        if (at == null) continue;
        binding.handlePointerEvent(PointerHoverEvent(position: at, kind: PointerDeviceKind.mouse, device: device));
        await _wait(2500);
      }
      if (fullscreen) {
        container.read(playerViewProvider.notifier).setFullscreen(false);
        await _wait(4000);
        _say('FULLSCREEN off');
      }
      _say('done');
      await stderr.flush();
      return;
    }

    if (mode == 'openclick') {
      // What a person does: rest the pointer on a tile until its preview plays, click,
      // and leave the pointer where it is while the watch page loads.
      final binding = GestureBinding.instance;
      const device = 9;
      final now = view.physicalSize / view.devicePixelRatio;
      _say('window now $now');
      // `RILL_FOCUS_PROBE_AT=0.82,0.4` (fractions of the window): a tile in the right-hand column
      // leaves the pointer over the watch page's related rail once the page opens.
      final fractions = (Platform.environment['RILL_FOCUS_PROBE_AT'] ?? '0.3,0.35').split(',').map(double.parse).toList();
      final at = Offset(now.width * fractions[0], now.height * fractions[1]);
      binding.handlePointerEvent(PointerAddedEvent(position: at, kind: PointerDeviceKind.mouse, device: device));
      binding.handlePointerEvent(PointerHoverEvent(position: at, kind: PointerDeviceKind.mouse, device: device));
      await _wait(3000);
      _say('CLICK tile at $at');
      binding.handlePointerEvent(PointerDownEvent(position: at, kind: PointerDeviceKind.mouse, device: device, buttons: kPrimaryButton));
      binding.handlePointerEvent(PointerUpEvent(position: at, kind: PointerDeviceKind.mouse, device: device));
      await _wait(10000);
      _say('done');
      await stderr.flush();
      return;
    }

    if (mode == 'hover') {
      // The mouse, not the keyboard: sweep a pointer over the feed (tile hover
      // previews), then over the watch page and the miniplayer.
      final binding = GestureBinding.instance;
      const device = 7;
      binding.handlePointerEvent(const PointerAddedEvent(position: Offset(5, 5), kind: PointerDeviceKind.mouse, device: device));
      Future<void> sweep(String label, double w, double h) async {
        _say('HOVER $label');
        for (var y = 0.2; y < 0.95; y += 0.25) {
          for (var x = 0.15; x < 0.95; x += 0.2) {
            binding.handlePointerEvent(PointerHoverEvent(position: Offset(window.width * x, window.height * y), kind: PointerDeviceKind.mouse, device: device));
            await _wait(1300);
          }
        }
      }

      await sweep('feed', window.width, window.height);
      openWatchIn(container, placeholderVideoItem('dQw4w9WgXcQ'));
      await _wait(12000);
      await sweep('watch', window.width, window.height);
      // Hover the Back button until its tooltip is up, then click it: the arrow fades
      // out while the tooltip is showing.
      _say('HOVER back, click');
      const back = Offset(95, 26);
      binding.handlePointerEvent(const PointerHoverEvent(position: back, kind: PointerDeviceKind.mouse, device: device));
      await _wait(1800);
      binding.handlePointerEvent(const PointerDownEvent(position: back, kind: PointerDeviceKind.mouse, device: device, buttons: kPrimaryButton));
      binding.handlePointerEvent(const PointerUpEvent(position: back, kind: PointerDeviceKind.mouse, device: device));
      await _wait(3000);
      openWatchIn(container, placeholderVideoItem('dQw4w9WgXcQ'));
      await _wait(8000);
      toMiniPlayerIn(container);
      await _wait(3000);
      await sweep('feed+mini', window.width, window.height);
      _say('done');
      await stderr.flush();
      return;
    }

    if (mode == 'watch') {
      final id = Platform.environment['RILL_FOCUS_PROBE_VIDEO']?.trim().isNotEmpty == true
          ? Platform.environment['RILL_FOCUS_PROBE_VIDEO']!.trim()
          : 'dQw4w9WgXcQ';
      openWatchIn(container, placeholderVideoItem(id));
      await _wait(14000);
    }
    _say('window=$window mode=$mode reverse=$reverse');

    // A keyboard session: focus highlights on, and a real Tab key event before each
    // step, which is what wakes the player controls when they have auto-hidden.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    for (var i = 0; i < stops; i++) {
      HardwareKeyboard.instance.handleKeyEvent(KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.tab,
        logicalKey: LogicalKeyboardKey.tab,
        timeStamp: Duration.zero,
      ));
      HardwareKeyboard.instance.handleKeyEvent(KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.tab,
        logicalKey: LogicalKeyboardKey.tab,
        timeStamp: Duration.zero,
      ));
      await _wait(150);
      final current = FocusManager.instance.primaryFocus;
      if (current == null || current.context == null) {
        FocusManager.instance.rootScope.nextFocus();
      } else {
        try {
          reverse ? current.previousFocus() : current.nextFocus();
        } on Object {
          // A node that was just replaced: start over from the top of the tree.
          FocusManager.instance.rootScope.nextFocus();
        }
      }
      await _wait();
      final node = FocusManager.instance.primaryFocus;
      if (node == null) {
        _say('FOCUS $i: none');
        continue;
      }
      final rect = node.rect;
      final off = rect.bottom > window.height || rect.top < 0 || rect.right > window.width || rect.left < 0;
      _say('FOCUS $i: ${describeFocusNode(node)} | ${rect.left.round()},${rect.top.round()} ${rect.width.round()}x${rect.height.round()}${off ? ' OFFSCREEN' : ''}');
      if (dwell > 0) {
        // Long enough for the controls' auto-hide to fire if it is going to.
        await _wait(dwell);
        _say('BAR $i: visible=${container.read(playerControlsVisibleProvider)}');
      }
    }
    _say('done');
  } on Object catch (error, stack) {
    _say('FAILED $error\n$stack');
    exit(1);
  }
  await stderr.flush();
  exit(0);
}
