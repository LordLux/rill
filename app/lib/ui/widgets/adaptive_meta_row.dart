import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class AdaptiveMetaRow extends MultiChildRenderObjectWidget {
  AdaptiveMetaRow({super.key, 
    required Widget meta,
    required Widget actions,
    this.spacing = 32.0, // The threshold gap
  }) : super(children: [meta, actions]);

  /// The threshold gap between the two children, below which they will be stacked vertically instead of horizontally
  final double spacing;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderAdaptiveMetaRow(spacing: spacing);
  }

  @override
  void updateRenderObject(BuildContext context, covariant RenderAdaptiveMetaRow renderObject) {
    renderObject.spacing = spacing;
  }
}

class _AdaptiveMetaRowParentData extends ContainerBoxParentData<RenderBox> {}

class RenderAdaptiveMetaRow extends RenderBox with ContainerRenderObjectMixin<RenderBox, _AdaptiveMetaRowParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _AdaptiveMetaRowParentData> {
  RenderAdaptiveMetaRow({required this._spacing});

  double _spacing;
  set spacing(double value) {
    if (_spacing == value) return;

    _spacing = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _AdaptiveMetaRowParentData) child.parentData = _AdaptiveMetaRowParentData();
  }

  @override
  void performLayout() {
    final constraints = this.constraints;
    final left = firstChild!;
    final right = lastChild!;

    final innerConstraints = BoxConstraints(maxWidth: constraints.maxWidth);
    left.layout(innerConstraints, parentUsesSize: true);
    right.layout(innerConstraints, parentUsesSize: true);

    // An unbounded parent (inside a horizontal `Row`, say) has an infinite
    // `maxWidth`, and every offset below that is measured from it would be
    // `Offset(Infinity, 0)` — a layout-phase crash. There, the row is exactly as
    // wide as its two children and the gap between them.
    final maxWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : left.size.width + right.size.width + _spacing;

    // Check if both children can fit in a single row
    final bool isWide = (left.size.width + right.size.width + _spacing) <= maxWidth;

    final leftData = left.parentData as _AdaptiveMetaRowParentData;
    final rightData = right.parentData as _AdaptiveMetaRowParentData;

    if (isWide) {
      // ROW LAYOUT
      leftData.offset = Offset.zero;
      rightData.offset = Offset(maxWidth - right.size.width, 0);

      size = constraints.constrain(
        Size(
          maxWidth,
          math.max(left.size.height, right.size.height),
        ),
      );
    } else {
      // COLUMN LAYOUT
      leftData.offset = Offset.zero;
      rightData.offset = Offset(maxWidth - right.size.width, left.size.height + 12);

      size = constraints.constrain(
        Size(
          maxWidth,
          left.size.height + 12 + right.size.height, // 12 is vertical runSpacing
        ),
      );
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}
