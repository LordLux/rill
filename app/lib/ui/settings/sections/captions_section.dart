import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/caption_style.dart';
import '../../captions_controller.dart';
import '../../player/settings_menu.dart' show captionEdgeOptions, captionFontOptions;
import '../settings_section.dart';
import '../settings_widgets.dart';

/// The "Remember caption style" switch; tests find it by this key.
const ValueKey<String> keepCaptionStyleSwitchKey = ValueKey('keep-caption-style-switch');

/// The "Override the video's style" switch.
const ValueKey<String> forceCaptionStyleSwitchKey = ValueKey('force-caption-style-switch');

const ValueKey<String> captionStyleResetKey = ValueKey('settings-caption-style-reset');

final SettingsSection captionsSection = SettingsSection(
  id: 'captions',
  title: 'Captions',
  icon: Icons.closed_caption_outlined,
  order: 30,
  builder: (_) => const _CaptionsSection(),
);

/// The caption style for every video.
///
/// **The same provider as the player's Style page, not a copy of it.** Both write
/// `captionsProvider`'s style; the player's page is there to judge a style over a picture,
/// this one is where the app-wide default lives. The style is remembered across videos
/// only while "Remember caption style" is on — off, a style lasts until the next video
/// (`CaptionsController._load`) — so the editor here only works while it is on: a default
/// that the next video throws away is not a default.
///
/// No `Slider`s: this page scrolls, and a Material slider's overlay is orphaned when its
/// anchor scrolls away (CLAUDE.md, "Accessibility"). Opacity is the slider's own six stops
/// as chips, and size a stepper.
class _CaptionsSection extends ConsumerWidget {
  const _CaptionsSection();

  static const List<({String label, double? value})> _opacities = [
    (label: 'Default', value: null),
    (label: '0%', value: 0.0),
    (label: '25%', value: 0.25),
    (label: '50%', value: 0.5),
    (label: '75%', value: 0.75),
    (label: '100%', value: 1.0),
  ];

  static const double _minSize = 50;
  static const double _maxSize = 300;
  static const double _sizeStep = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keep = ref.watch(keepCaptionStyleProvider);
    final captions = ref.watch(captionsProvider);
    final style = captions.style;
    final controller = ref.read(captionsProvider.notifier);

    void apply(CaptionStyle next) => unawaited(controller.setStyle(next, immediate: true));
    // Every editing control is greyed out while the style is not being remembered.
    ValueChanged<T>? when<T>(ValueChanged<T> onPicked) => keep ? onPicked : null;

    final size = style.fontSizePercent ?? 100;
    final sizeText = '${size.round()}%';

    List<({String name, Color? color, Color? value})> swatches() => [
      for (var i = 0; i < captionPalette.length; i++)
        (name: captionPaletteNames[i], color: captionPalette[i], value: captionPalette[i]),
    ];

    // RGB alone: opacity is its own field, as on the player's Style page.
    bool Function(Color?) sameColour(Color? current) => (Color? swatch) {
      if (swatch == null || current == null) return swatch == null && current == null;
      return swatch.r == current.r && swatch.g == current.g && swatch.b == current.b;
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          children: [
            SettingsSwitchRow(
              switchKey: keepCaptionStyleSwitchKey,
              label: 'Remember caption style',
              detail: keep
                  ? 'Every video uses the style below. Changes show on the video playing now.'
                  : 'Off: a style set from the player lasts until the next video. Turn on to use one style for every video.',
              value: keep,
              onChanged: (value) => unawaited(ref.read(keepCaptionStyleProvider.notifier).set(value)),
            ),
          ],
        ),
        SettingsCard(
          title: 'Text',
          children: [
            SettingsLabelledRow(
              label: 'Font',
              child: SettingsChoiceChips<String?>(
                label: 'Font',
                value: style.fontFamily,
                options: captionFontOptions,
                onPicked: when((family) => apply(style.copyWith(fontFamily: family))),
              ),
            ),
            SettingsLabelledRow(
              label: 'Size',
              child: Align(
                alignment: Alignment.centerLeft,
                child: SettingsStepper(
                  label: 'caption size',
                  valueText: sizeText,
                  onDecrease: keep && size > _minSize
                      ? () => apply(style.copyWith(fontSizePercent: _sized(size - _sizeStep)))
                      : null,
                  onIncrease: keep && size < _maxSize
                      ? () => apply(style.copyWith(fontSizePercent: _sized(size + _sizeStep)))
                      : null,
                ),
              ),
            ),
            SettingsLabelledRow(
              label: 'Colour',
              child: SettingsSwatches<Color?>(
                label: 'Text colour',
                options: swatches(),
                isSelected: sameColour(style.textColor),
                onPicked: when((colour) => apply(style.copyWith(textColor: colour))),
              ),
            ),
            SettingsLabelledRow(
              label: 'Opacity',
              child: SettingsChoiceChips<double?>(
                label: 'Text opacity',
                value: style.textOpacity,
                options: _opacities,
                onPicked: when((value) => apply(style.copyWith(textOpacity: value))),
              ),
            ),
            SettingsLabelledRow(
              label: 'Edge',
              child: SettingsChoiceChips<CaptionEdgeStyle?>(
                label: 'Character edge',
                value: style.edgeStyle,
                options: captionEdgeOptions,
                onPicked: when((edge) => apply(style.copyWith(edgeStyle: edge))),
              ),
            ),
          ],
        ),
        SettingsCard(
          title: 'Background',
          detail: 'Behind each line of text.',
          children: [
            SettingsLabelledRow(
              label: 'Colour',
              child: SettingsSwatches<Color?>(
                label: 'Background colour',
                options: swatches(),
                isSelected: sameColour(style.background),
                onPicked: when((colour) => apply(style.copyWith(background: colour))),
              ),
            ),
            SettingsLabelledRow(
              label: 'Opacity',
              child: SettingsChoiceChips<double?>(
                label: 'Background opacity',
                value: style.backgroundOpacity,
                options: _opacities,
                onPicked: when((value) => apply(style.copyWith(backgroundOpacity: value))),
              ),
            ),
          ],
        ),
        SettingsCard(
          title: 'Window',
          detail: 'One box around all the captions on screen. YouTube draws it at 0% unless you turn it up.',
          children: [
            SettingsLabelledRow(
              label: 'Colour',
              child: SettingsSwatches<Color?>(
                label: 'Window colour',
                options: swatches(),
                isSelected: sameColour(style.window),
                onPicked: when((colour) => apply(style.copyWith(window: colour))),
              ),
            ),
            SettingsLabelledRow(
              label: 'Opacity',
              child: SettingsChoiceChips<double?>(
                label: 'Window opacity',
                value: style.windowOpacity,
                options: _opacities,
                onPicked: when((value) => apply(style.copyWith(windowOpacity: value))),
              ),
            ),
          ],
        ),
        SettingsCard(
          title: 'Video overrides',
          detail: 'Some videos style their own captions. Choose which of your settings win anyway.',
          children: [
            SettingsSwitchRow(
              switchKey: forceCaptionStyleSwitchKey,
              label: "Override the video's style",
              value: style.forceStyleEnabled,
              onChanged: when((value) => apply(style.copyWith(forceStyleEnabled: value))),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (label, on, set) in <(String, bool, CaptionStyle Function(bool))>[
                  ('Font', style.forceFontFamily, (v) => style.copyWith(forceFontFamily: v)),
                  ('Size', style.forceFontSize, (v) => style.copyWith(forceFontSize: v)),
                  ('Text colour', style.forceTextColor, (v) => style.copyWith(forceTextColor: v)),
                  ('Text opacity', style.forceTextOpacity, (v) => style.copyWith(forceTextOpacity: v)),
                  ('Background colour', style.forceBackgroundColor, (v) => style.copyWith(forceBackgroundColor: v)),
                  ('Background opacity', style.forceBackgroundOpacity, (v) => style.copyWith(forceBackgroundOpacity: v)),
                  ('Window colour', style.forceWindowColor, (v) => style.copyWith(forceWindowColor: v)),
                  ('Window opacity', style.forceWindowOpacity, (v) => style.copyWith(forceWindowOpacity: v)),
                  ('Edge', style.forceEdgeStyle, (v) => style.copyWith(forceEdgeStyle: v)),
                ])
                  _OverrideChip(
                    label: label,
                    on: on,
                    // The nine depend on the switch, as on the player's page.
                    onChanged: keep && style.forceStyleEnabled ? (v) => apply(set(v)) : null,
                  ),
              ],
            ),
          ],
        ),
        SettingsCard(
          children: [
            SettingsLinkRow(
              key: captionStyleResetKey,
              icon: Icons.restart_alt,
              label: 'Reset caption style',
              detail: "Back to each video's own style, and the caption back where it was.",
              onTap: keep && !(style.isDefault && captions.offset.isZero)
                  ? () => unawaited(controller.resetStyle())
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  static double? _sized(double value) {
    final clamped = value.clamp(_minSize, _maxSize).toDouble();
    // 100% is the track's own size, which is what null says.
    return clamped == 100 ? null : clamped;
  }
}

/// One of the nine overrides: a chip that is on or off.
class _OverrideChip extends StatelessWidget {
  const _OverrideChip({required this.label, required this.on, required this.onChanged});

  final String label;
  final bool on;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final active = on && enabled;
    final background = active ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final foreground = active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Semantics(
      label: 'Override $label',
      toggled: on,
      enabled: enabled,
      child: Material(
        color: background,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: enabled ? () => onChanged!(!on) : null,
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(on ? Icons.check : Icons.add, size: 14, color: enabled ? foreground : foreground.withValues(alpha: 0.5)),
                  const SizedBox(width: 4),
                  Text(label, style: TextStyle(fontSize: 12, color: enabled ? foreground : foreground.withValues(alpha: 0.5))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
