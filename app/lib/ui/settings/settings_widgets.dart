import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../theme/accent.dart';
import '../../theme/app_theme.dart';

/// The pieces every settings section is built from, so the sections look alike and a
/// screen reader hears each control once, with its state.
///
/// **No overlays here, on purpose.** The page scrolls and its sections swap, and a Material
/// `Slider`, `Tooltip`, `MenuAnchor` or `DropdownButton` hosts a semantics node grafted under
/// its anchor that is orphaned when the anchor goes (CLAUDE.md, "Accessibility"). Choices
/// are chips, numbers are steppers, and nothing has a tooltip.

/// A titled group of rows: the account menu's panel look, at page width.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, this.title, this.detail, required this.children});

  final String? title;

  /// A line under the title, saying what the whole group is for.
  final String? detail;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: const BorderRadius.all(Radius.circular(16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Semantics(
              header: true,
              child: Text(title!, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            ),
          if (detail != null) ...[
            const SizedBox(height: 2),
            Text(detail!, style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
          if (title != null || detail != null) const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

/// A small caps label between groups of rows inside one card.
class SettingsGroupLabel extends StatelessWidget {
  const SettingsGroupLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Semantics(
        header: true,
        child: Text(
          label.toUpperCase(),
          style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// A label, a line of detail, and a switch: one semantics node that says all three.
///
/// The switch is the Tab stop; a click anywhere on the row flips it too.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.label,
    this.detail,
    required this.value,
    required this.onChanged,
    this.switchKey,
  });

  final String label;
  final String? detail;
  final bool value;

  /// Null greys the row out and leaves the switch where it is.
  final ValueChanged<bool>? onChanged;

  final Key? switchKey;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final labelColor = enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.5);
    return MergeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: textTheme.bodyMedium?.copyWith(color: labelColor)),
                    if (detail != null)
                      Text(detail!, style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch(key: switchKey, value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// A label on the left and a control on the right, for the rows that are not switches.
class SettingsLabelledRow extends StatelessWidget {
  const SettingsLabelledRow({super.key, required this.label, required this.child, this.labelWidth = 120});

  final String label;
  final Widget child;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: labelWidth,
            // The control names itself, with this label in it; read once, there.
            child: ExcludeSemantics(child: Text(label, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// One of a few choices, as a row of chips. Each chip is a Tab stop and says whether it is
/// the one chosen.
class SettingsChoiceChips<T> extends StatelessWidget {
  const SettingsChoiceChips({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onPicked,
  });

  /// What the group is, said with each chip ("Font: Arial").
  final String label;
  final T value;
  final List<({String label, T value})> options;

  /// Null greys the chips out.
  final ValueChanged<T>? onPicked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPicked != null;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final option in options)
          Builder(
            builder: (context) {
              final selected = option.value == value;
              final background = selected ? scheme.primary : scheme.surfaceContainerHighest;
              final foreground = selected ? scheme.onPrimary : scheme.onSurface;
              return Semantics(
                button: true,
                selected: selected,
                inMutuallyExclusiveGroup: true,
                enabled: enabled,
                label: '$label: ${option.label}',
                child: Material(
                  color: enabled ? background : background.withValues(alpha: 0.5),
                  shape: const StadiumBorder(),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: enabled ? () => onPicked!(option.value) : null,
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Text(
                          option.label,
                          style: TextStyle(fontSize: 12, color: enabled ? foreground : foreground.withValues(alpha: 0.6)),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// Colour swatches, one Tab stop each, named for a screen reader.
class SettingsSwatches<T> extends StatelessWidget {
  const SettingsSwatches({
    super.key,
    required this.label,
    required this.options,
    required this.isSelected,
    required this.onPicked,
    this.size = 24,
  });

  final String label;

  /// Each swatch: its name, the colour drawn (null draws "none"), and the value picked.
  final List<({String name, Color? color, T value})> options;
  final bool Function(T value) isSelected;

  /// Null greys the swatches out.
  final ValueChanged<T>? onPicked;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPicked != null;
    return Opacity(
      // Semantics are kept: the swatches stay in the tree with `enabled: false`.
      opacity: enabled ? 1 : 0.5,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final option in options)
            Builder(
              builder: (context) {
                final selected = isSelected(option.value);
                return Semantics(
                  button: true,
                  selected: selected,
                  inMutuallyExclusiveGroup: true,
                  enabled: enabled,
                  label: '$label: ${option.name}',
                  child: Material(
                    type: MaterialType.transparency,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: enabled ? () => onPicked!(option.value) : null,
                      child: ExcludeSemantics(
                        child: Container(
                        width: size,
                        height: size,
                        decoration: BoxDecoration(
                          // The one place a raw colour is painted: here the colour itself is
                          // the thing being chosen.
                          color: option.color ?? scheme.surfaceContainerHighest,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? scheme.onSurface : scheme.outlineVariant,
                            width: selected ? 3 : 1,
                          ),
                        ),
                        child: option.color == null ? Icon(Icons.remove, size: size / 2, color: scheme.onSurfaceVariant) : null,
                      ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// A number with − and + beside it. Each button is a Tab stop named for what it does and
/// the value it leaves.
class SettingsStepper extends StatelessWidget {
  const SettingsStepper({
    super.key,
    required this.label,
    required this.valueText,
    required this.onDecrease,
    required this.onIncrease,
  });

  final String label;
  final String valueText;

  /// Null at the end of the range, or when the stepper is greyed out.
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: onDecrease,
          icon: Icon(Icons.remove, size: 18, semanticLabel: 'Decrease $label, now $valueText'),
        ),
        SizedBox(
          width: 56,
          child: Semantics(
            liveRegion: true,
            label: '$label $valueText',
            excludeSemantics: true,
            child: Text(valueText, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: onIncrease,
          icon: Icon(Icons.add, size: 18, semanticLabel: 'Increase $label, now $valueText'),
        ),
      ],
    );
  }
}

/// A row that opens something (a dialog, a page): label, detail, and a chevron.
class SettingsLinkRow extends StatelessWidget {
  const SettingsLinkRow({super.key, required this.icon, required this.label, this.detail, required this.onTap});

  final IconData icon;
  final String label;
  final String? detail;

  /// Null greys the row out.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final enabled = onTap != null;
    return Semantics(
      enabled: enabled,
      button: true,
      label: detail == null ? label : '$label. $detail',
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        onTap: onTap,
        child: ExcludeSemantics(
          child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            children: [
              Icon(icon, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: textTheme.bodyMedium?.copyWith(color: enabled ? null : scheme.onSurface.withValues(alpha: 0.5))),
                    if (detail != null) Text(detail!, style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

// --- Previews ---

Widget _previewCard({required bool enabled}) => SettingsCard(
      title: enabled ? 'Enabled' : 'Greyed out',
      detail: 'A line saying what the group is for.',
      children: [
        SettingsSwitchRow(label: 'A switch', detail: 'What it does.', value: true, onChanged: enabled ? (_) {} : null),
        SettingsLabelledRow(
          label: 'Choice',
          child: SettingsChoiceChips<int>(
            label: 'Choice',
            value: 1,
            options: const [(label: 'Default', value: 0), (label: 'One', value: 1), (label: 'Two', value: 2)],
            onPicked: enabled ? (_) {} : null,
          ),
        ),
        SettingsLabelledRow(
          label: 'Colour',
          child: SettingsSwatches<Color>(
            label: 'Colour',
            options: [for (final preset in kAccentPresets) (name: preset.name, color: preset.seed, value: preset.seed)],
            isSelected: (seed) => seed == kDefaultAccent,
            onPicked: enabled ? (_) {} : null,
          ),
        ),
        SettingsLabelledRow(
          label: 'Size',
          child: Align(
            alignment: Alignment.centerLeft,
            child: SettingsStepper(label: 'size', valueText: '120%', onDecrease: enabled ? () {} : null, onIncrease: enabled ? () {} : null),
          ),
        ),
        SettingsLinkRow(icon: Icons.restart_alt, label: 'A link row', detail: 'Opens something.', onTap: enabled ? () {} : null),
      ],
    );

/// The app has one theme, dark; enabled and greyed out side by side is the useful pair.
@Preview(name: 'Settings rows')
Widget settingsRowsPreview() => MaterialApp(
      theme: buildRillTheme(kDefaultAccent),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 560,
            child: Column(children: [_previewCard(enabled: true), _previewCard(enabled: false)]),
          ),
        ),
      ),
    );
