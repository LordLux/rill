import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

/// Bans colour literals in `lib/ui/`.
///
/// Same reasoning as the sidecar's stdout rule (hard invariant 3, enforced by
/// `no-console` in `sidecar/eslint.config.js`): a discipline that depends on
/// remembering is a discipline that decays. The accent is a *seed* run through
/// `ColorScheme.fromSeed`, and every widget paints with a role derived from it.
/// One `Color(0xFF…)` slipped into a tile is invisible in review and simply does
/// not re-theme — it looks fine until someone changes the accent, and then it is
/// the one thing on screen that did not move.
///
/// Colours are named in exactly two files, both outside `lib/ui/`:
/// `lib/theme/accent.dart` (the seed and its presets) and `lib/theme/tokens.dart`
/// (the handful of things that are genuinely not roles — the thumbnail scrim,
/// the LIVE status red). That is the scope this rule draws.
class NoColorLiterals extends AnalysisRule {
  NoColorLiterals()
    : super(
        name: 'no_color_literals',
        description:
            'Colour literals do not re-theme. Use a ColorScheme role, or a '
            'token from lib/theme/tokens.dart.',
      );

  static const LintCode _code = LintCode(
    'no_color_literals',
    "Colour literal '{0}' in lib/ui/.",
    correctionMessage:
        'Use a ColorScheme role (Theme.of(context).colorScheme.…), or add a '
        'token in lib/theme/tokens.dart if it is genuinely not a role.',
  );

  @override
  DiagnosticCode get diagnosticCode => _code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    // Scoping lives here rather than in analysis options: plugin rules cannot be
    // enabled, disabled or configured in a nested `analysis_options.yaml`, so
    // "only under lib/ui/" has to be the rule's own decision. That also keeps
    // generated code (`*.g.dart`, `*.freezed.dart`) and tests out of it for
    // free — none of them live there.
    final path = context.definingUnit.file.path.replaceAll(r'\', '/');
    if (!path.contains('/lib/ui/')) return;
    if (path.endsWith('.g.dart') || path.endsWith('.freezed.dart')) return;

    final visitor = _Visitor(this);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addPrefixedIdentifier(this, visitor);
    registry.addPropertyAccess(this, visitor);
  }
}

/// `Colors.transparent` carries no colour. It means "paint nothing", it cannot
/// clash with any accent, and there is no role that says it — `Colors` is simply
/// where Flutter keeps the constant.
const String _transparent = 'transparent';

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);

  final AnalysisRule rule;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    // Color(0xFF…), Color.fromARGB(…), Color.fromRGBO(…), and any other
    // constructor on the class.
    final type = node.constructorName.type.element;
    if (type == null || type.name != 'Color') return;
    if (!_isFlutterUi(type)) return;
    rule.reportAtNode(node, arguments: [node.toString()]);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    // Colors.white, Colors.grey (the target of Colors.grey[800]).
    if (node.identifier.name == _transparent) return;
    if (!_isColorsClass(node.prefix.element)) return;
    rule.reportAtNode(node, arguments: [node.toString()]);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    // Colors.grey.shade500, and Colors.x reached through any other target.
    if (node.propertyName.name == _transparent) return;
    final target = node.target;
    if (target is Identifier && _isColorsClass(target.element)) {
      rule.reportAtNode(node, arguments: [node.toString()]);
    }
  }

  /// Matches Flutter's `Colors`, not a same-named class from somewhere else.
  static bool _isColorsClass(Element? element) =>
      element is ClassElement &&
      element.name == 'Colors' &&
      element.library.uri.toString().startsWith('package:flutter/');

  static bool _isFlutterUi(Element element) {
    final uri = element.library?.uri.toString() ?? '';
    return uri.startsWith('dart:ui') || uri.startsWith('package:flutter/');
  }
}
