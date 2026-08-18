import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../captions_controller.dart';
import 'settings_menu.dart';

class CaptionsOverlay extends ConsumerWidget {
  const CaptionsOverlay({super.key, required this.controlsVisible});

  final bool controlsVisible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(captionsProvider);
    final isMenuOpen = ref.watch(playerMenuProvider.select((m) => m.open));

    if (!state.enabled || state.currentCue == null) return const SizedBox.shrink();

    final text = state.currentCue!.text;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      bottom: controlsVisible || isMenuOpen ? 70.0 : 30.0,
      left: 20.0,
      right: 20.0,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(4.0),
              ),
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18.0,
                  fontWeight: FontWeight.w500,
                  shadows: [
                    Shadow(offset: Offset(1.0, 1.0), color: Colors.black, blurRadius: 2.0),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
