/// `RILL_KEY_DIAG=1` — log what the keyboard and focus are doing, to stderr (and so to the
/// release log), for a "the keyboard stopped working" report.
///
/// If a key press shows up here, the platform is delivering keys and the fault is in the app's
/// focus handling; if the line stops appearing for presses, the window itself has lost
/// keyboard focus (the log says when, via the lifecycle and view-focus lines). Off, this costs
/// one environment lookup at startup.
library;

import 'dart:io';
import 'dart:ui' show ViewFocusEvent;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

void runKeyDiag() {
  if (Platform.environment['RILL_KEY_DIAG'] != '1') return;
  final binding = WidgetsBinding.instance;
  final observer = _Observer();
  binding.addObserver(observer);

  String where() {
    final node = FocusManager.instance.primaryFocus;
    final context = node?.context;
    final state = context == null ? 'no context' : (context.mounted ? 'mounted' : 'UNMOUNTED');
    return 'focus=${node == null ? 'none' : (node.debugLabel ?? node.runtimeType.toString())} ($state) mode=${FocusManager.instance.highlightMode.name} life=${binding.lifecycleState?.name}';
  }

  HardwareKeyboard.instance.addHandler((event) {
    // `down` lists every key Flutter believes is held, including after this press: a modifier
    // whose release never arrived (Win+Arrow is eaten by the shell) stays in it, and every
    // shortcut and Tab ignores a press made "with" a modifier.
    if (event is KeyDownEvent) {
      final down = HardwareKeyboard.instance.logicalKeysPressed.map((k) => k.debugName ?? k.keyLabel).join('+');
      stderr.writeln('keydiag: ${event.logicalKey.keyLabel.isEmpty ? event.logicalKey.debugName : event.logicalKey.keyLabel} down=[$down] ${where()}');
    }
    return false;
  });
  FocusManager.instance.addListener(() => stderr.writeln('keydiag: focus changed -> ${where()}'));
  stderr.writeln('keydiag: on. ${where()}');
}

class _Observer with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => stderr.writeln('keydiag: lifecycle -> ${state.name}');

  @override
  void didChangeViewFocus(ViewFocusEvent event) =>
      stderr.writeln('keydiag: view ${event.viewId} focus -> ${event.state.name} (${event.direction.name})');
}
