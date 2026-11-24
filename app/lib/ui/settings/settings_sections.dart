import 'sections/about_section.dart';
import 'sections/captions_section.dart';
import 'sections/feeds_section.dart';
import 'sections/general_section.dart';
import 'settings_section.dart';

/// Every section of the settings page — **the one place a section is registered.**
///
/// The sidebar and the content are built from this list, sorted by
/// [SettingsSection.order]. To add a page: write `sections/<name>_section.dart` exporting a
/// `SettingsSection`, and add it here. Reserved slots: Zoom (Task 41) at 40, Audio
/// languages (`todo.md` 84 point 3) at 50.
final List<SettingsSection> settingsSections = List.unmodifiable(
  [
    generalSection,
    feedsSection,
    captionsSection,
    aboutSection,
  ]..sort((a, b) => a.order.compareTo(b.order)),
);
