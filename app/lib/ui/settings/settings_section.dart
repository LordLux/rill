import 'package:flutter/widgets.dart';

/// One page of the settings page: an entry in its sidebar and what shows beside it.
///
/// **A section is one file under `sections/` and one line in `settings_sections.dart`.**
/// The page builds its sidebar and its content from that list and nothing else, so a later
/// task (Zoom, Audio languages) adds a page without touching the page itself.
///
/// An app-wide setting lives here and only here. What belongs to the video playing now
/// stays in the player's menu (`todo.md` 69's rule): quality, this video's captions, audio
/// only, the sleep timer.
@immutable
class SettingsSection {
  const SettingsSection({
    required this.id,
    required this.title,
    required this.icon,
    required this.order,
    required this.builder,
  });

  /// Stable, for opening the page at this section (`openSettingsPage(section: …)`).
  final String id;

  /// The sidebar's label and the page's heading.
  final String title;

  final IconData icon;

  /// Where it sits in the sidebar, smallest first. Spaced by ten so a later section
  /// slots in between without renumbering: General 10, Feeds 20, Captions 30, Zoom 40,
  /// Audio languages 50, About 90.
  final double order;

  /// The section's content: a column of [SettingsCard]s.
  final WidgetBuilder builder;
}
