import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'player_shell.dart' show miniPlayerScopeProvider, miniPlayerShownProvider;

/// The miniplayer's place in a page's Tab order: **first among the page's content**
/// (after the title bar, rail, search and account), on every page that has one on
/// screen (every page but the watch page).
///
/// The miniplayer lives above the `Navigator` and Tab never leaves a route's focus
/// scope, so on its own it is unreachable (F6 is the other way in). This is a
/// zero-size stop at the very front of the page's order that hands focus straight
/// to the miniplayer's scope; and the miniplayer hands it back through [leave] when
/// Tab runs off either end of its controls — forwards to the page's next stop,
/// backwards to its last one. Nothing to see and nothing to hear: it has no
/// semantics, and it is not a stop at all while there is no miniplayer.
class MiniPlayerStop extends ConsumerStatefulWidget {
  const MiniPlayerStop({super.key});

  /// Tab left the miniplayer's controls. [forward] is the direction of travel.
  /// False when there is no page stop to continue from.
  static bool leave({required bool forward}) {
    for (final state in _live.reversed) {
      final context = state.context;
      if (!state.mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) continue;
      state._leave(forward);
      return true;
    }
    return false;
  }

  static final List<_MiniPlayerStopState> _live = [];

  @override
  ConsumerState<MiniPlayerStop> createState() => _MiniPlayerStopState();
}

class _MiniPlayerStopState extends ConsumerState<MiniPlayerStop> {
  final FocusNode _node = FocusNode(debugLabel: 'miniplayer stop');

  @override
  void initState() {
    super.initState();
    MiniPlayerStop._live.add(this);
  }

  @override
  void dispose() {
    MiniPlayerStop._live.remove(this);
    _node.dispose();
    super.dispose();
  }

  /// Set while this hands focus on, so the stop is not "entered" on the way past.
  bool _passing = false;

  void _leave(bool forward) {
    _passing = true;
    if (forward) {
      _node.nextFocus();
    } else {
      _node.previousFocus();
    }
    // The stop is the last one in the page when the page has nothing after it, and
    // "next" then wraps round to... the stop itself (a scope's own `focusedChild` wins
    // over its first node). Start the page over instead.
    Future<void>.microtask(() {
      final pageScope = _node.nearestScope;
      final ctx = pageScope?.context;
      if (mounted && pageScope != null && ctx != null && ctx.mounted && FocusManager.instance.primaryFocus == _node) {
        FocusTraversalGroup.of(ctx).findFirstFocus(pageScope, ignoreCurrentFocus: true)?.requestFocus();
      }
      Future<void>.microtask(() => _passing = false);
    });
  }

  void _enter() {
    if (_passing) return;
    final scope = ref.read(miniPlayerScopeProvider);
    if (scope.context == null) return;
    final backwards = HardwareKeyboard.instance.isShiftPressed;
    // After this focus change has finished applying.
    Future<void>.microtask(() {
      final scopeContext = scope.context;
      if (!mounted || scopeContext == null || !scopeContext.mounted) return;
      // A control, never the scope itself (a scope with focus has nothing to press).
      final policy = FocusTraversalGroup.of(scopeContext);
      final target = backwards ? policy.findLastFocus(scope, ignoreCurrentFocus: true) : policy.findFirstFocus(scope, ignoreCurrentFocus: true);
      (target ?? scope).requestFocus();

    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = ref.watch(miniPlayerShownProvider);
    _node
      ..skipTraversal = !shown
      ..canRequestFocus = shown;
    return FocusTraversalOrder(
      // Between the top-bar actions (4) and the page content (5): first *in the page*, after
      // the title bar, rail, search and account.
      order: const NumericFocusOrder(4.5),
      child: Focus(
        focusNode: _node,
        includeSemantics: false,
        onFocusChange: (has) {
          if (has && ref.read(miniPlayerShownProvider)) _enter();
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}
