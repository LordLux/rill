import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/accent.dart';

/// **TEMPORARY.** A swatch row behind a debug action in the top bar.
///
/// This is not the settings surface — that is a later task, and this widget goes
/// away when it lands. It exists because "the accent is user-changeable" is not
/// a claim anyone can check without a way to change it, and an untested claim
/// about persistence is worth nothing.
class AccentDebugButton extends ConsumerWidget {
  const AccentDebugButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final current = ref.watch(accentProvider);

    return MenuAnchor(
      builder: (context, controller, child) => IconButton(
        icon: Icon(Icons.palette_outlined, color: scheme.onSurface),
        tooltip: 'Accent (temporary debug control)',
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final preset in kAccentPresets)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Tooltip(
                    message: preset.name,
                    child: InkWell(
                      onTap: () => ref.read(accentProvider.notifier).set(preset.seed),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          // The one place a raw seed is painted, because here the
                          // seed itself is the thing being chosen. Everywhere
                          // else it is only ever an input to `fromSeed`.
                          color: preset.seed,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: preset.seed == current ? scheme.onSurface : scheme.outlineVariant,
                            width: preset.seed == current ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
