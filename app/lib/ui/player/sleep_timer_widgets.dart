/// What the sleep timer puts on screen (Task 38): the moon in the controls bar and the miniplayer,
/// the note after it fired, and the countdown before a system action.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/tokens.dart';
import '../sleep_timer.dart';
import '../spoken.dart';
import '../widgets/shortcut_tooltip.dart';

const Key sleepTimerIndicatorKey = ValueKey('sleep-timer-indicator');
const Key sleepNoteKey = ValueKey('sleep-note');
const Key sleepCountdownKey = ValueKey('sleep-countdown');
const Key sleepCountdownCancelKey = ValueKey('sleep-countdown-cancel');

/// The moon, with the time left for a countdown. For the kinds without a time the moon shows
/// alone, and the tooltip says what it waits for and the action after it. Nothing while it is off.
///
/// Informational, not a control: it is not focusable, and it names itself once for a screen reader
/// (the spoken time, never digits — `spoken.dart`).
class SleepTimerIndicator extends ConsumerWidget {
  const SleepTimerIndicator({super.key, this.side = TooltipSide.above, this.color, this.showTime = true});

  /// Where the bubble opens. [TooltipSide.left] in the miniplayer, which clips above itself.
  final TooltipSide side;

  /// The foreground; the ambient icon theme when null.
  final Color? color;

  /// False draws the moon alone even for a countdown, where the bar has no room for the time (the
  /// vertical layout, whose only flex child is the scrubber). The tooltip and the spoken label
  /// still carry it.
  final bool showTime;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(sleepTimerProvider);
    if (!timer.isOn) return const SizedBox.shrink();
    final action = ref.watch(sleepEndActionProvider);
    final time = timer.kind == SleepKind.duration ? formatSleepLeft(timer.left ?? Duration.zero) : null;
    final summary = sleepTimerSummary(timer, action);
    final spoken = 'Sleep timer: ${sleepTimerSpokenSummary(timer, action)}';

    return ShortcutTooltip(
      silent: true,
      announce: false,
      side: side,
      label: 'Sleep timer: $summary',
      child: Semantics(
        container: true,
        label: spoken,
        child: ExcludeSemantics(
          child: Padding(
            key: sleepTimerIndicatorKey,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bedtime, size: 18, color: color),
                if (time != null && showTime) ...[
                  const SizedBox(width: 4),
                  Text(time, style: TextStyle(fontSize: 12, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Sleep timer: paused", for a few seconds after it fired. Drawn the way `SwitchingNote` is — in
/// the control bar's row, pointer-transparent, one live region — and it is up when the pause has
/// just brought the bar back.
class SleepNoteView extends ConsumerWidget {
  const SleepNoteView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = ref.watch(sleepNoteProvider);
    if (note == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).tokens;
    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
          child: Semantics(
            container: true,
            liveRegion: true,
            label: note,
            child: ExcludeSemantics(
              child: DecoratedBox(
                key: sleepNoteKey,
                decoration: BoxDecoration(color: tokens.scrim.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(8)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bedtime, size: 16, color: tokens.onScrim),
                        const SizedBox(width: 8),
                        Text(note, style: TextStyle(color: tokens.onScrim, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Shutting down in 30 s", with *Cancel*, before Sleep, Hibernate, Shut down or Restart. Over the
/// whole window (`PlayerShell`), because the action is the machine's, whatever page is showing.
///
/// *Cancel* takes focus when it appears, so Enter or Space presses it, and Escape cancels from
/// anywhere: the keyboard cannot Tab to anything above the `Navigator`.
class SleepCountdownBanner extends ConsumerStatefulWidget {
  const SleepCountdownBanner({super.key});

  @override
  ConsumerState<SleepCountdownBanner> createState() => _SleepCountdownBannerState();
}

class _SleepCountdownBannerState extends ConsumerState<SleepCountdownBanner> {
  final FocusNode _cancel = FocusNode(debugLabel: 'sleep countdown cancel');
  bool _listening = false;

  /// What had focus when the countdown took it, to give back when it ends (Escape closes and focus
  /// returns, as for every overlay here).
  FocusNode? _before;

  @override
  void initState() {
    super.initState();
    if (ref.read(sleepEndProvider) != null) _start();
  }

  @override
  void dispose() {
    _stop();
    _cancel.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && ref.read(sleepEndProvider) != null) {
      ref.read(sleepEndProvider.notifier).cancel();
      return true;
    }
    return false;
  }

  void _start() {
    if (_listening) return;
    _listening = true;
    HardwareKeyboard.instance.addHandler(_onKey);
    _before = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _cancel.context != null) _cancel.requestFocus();
    });
  }

  void _stop() {
    if (!_listening) return;
    _listening = false;
    HardwareKeyboard.instance.removeHandler(_onKey);
    final before = _before;
    _before = null;
    if (!_cancel.hasFocus) return;
    if (before != null && before.context != null && before.canRequestFocus) {
      before.requestFocus();
    } else {
      _cancel.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Before the rebuild that removes the button, so focus can still be handed back from it.
    ref.listen<SleepCountdown?>(sleepEndProvider, (previous, next) {
      if (next != null) {
        _start();
      } else {
        _stop();
      }
    });
    final countdown = ref.watch(sleepEndProvider);
    if (countdown == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 56, left: 16, right: 16),
        child: Material(
          key: sleepCountdownKey,
          elevation: 8,
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bedtime, size: 18, color: scheme.onSurface),
                const SizedBox(width: 10),
                // Announced once, as it appears: a label that changed every second would be read
                // every second.
                Semantics(
                  container: true,
                  liveRegion: true,
                  label: '${countdown.verb} in ${spokenDuration(countdown.total)}. Press Escape to cancel.',
                  child: ExcludeSemantics(
                    child: Text(countdown.label, style: TextStyle(fontSize: 13, color: scheme.onSurface, fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  key: sleepCountdownCancelKey,
                  focusNode: _cancel,
                  onPressed: () => ref.read(sleepEndProvider.notifier).cancel(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
