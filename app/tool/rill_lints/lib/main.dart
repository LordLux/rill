import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/no_color_literals.dart';

/// The analysis server looks for a top-level `plugin` in `lib/main.dart`.
final plugin = RillLints();

class RillLints extends Plugin {
  @override
  String get name => 'rill_lints';

  @override
  void register(PluginRegistry registry) {
    registry.registerLintRule(NoColorLiterals());
  }
}
