/// Where the user put one dimension's label, in sketch units - the same in the flat canvas and the 3D sketch view, so it does not
/// go stale when the camera moves (docs/dimension-labels-scope.md, section 2.1). Saved on the backend with the sketch.
///
/// Which fields a dimension uses depends on its kind; a field left null means "use the default place for that part":
///
/// | Dimension | Fields |
/// |---|---|
/// | linear, horizontal, vertical, line-distance, point-line | [offset], [along] |
/// | radius, diameter | [angle] (degrees counter-clockwise from the rim point), [leg] (distance from the circle) |
/// | angle | [radius] (of the arc), [along] |
///
/// The meaning of each field per kind is fixed by [LabelDragResolver] (sketch/label_drag_resolver.dart), which is also what turns a
/// pointer position into one of these.
class DimensionLabelPlacement {
  final double? offset;
  final double? along;
  final double? angle;
  final double? leg;
  final double? radius;

  const DimensionLabelPlacement({this.offset, this.along, this.angle, this.leg, this.radius});

  bool get isEmpty => offset == null && along == null && angle == null && leg == null && radius == null;

  /// The backend's wire shape (`PUT .../constraints/{id}/label`): only the fields that are set.
  Map<String, double> toJson() => {
        if (offset != null) 'offset': offset!,
        if (along != null) 'along': along!,
        if (angle != null) 'angle': angle!,
        if (leg != null) 'leg': leg!,
        if (radius != null) 'radius': radius!,
      };

  /// Null when [json] is null or holds none of the known keys (an older server sends no `label`, a constraint with no saved placement sends null).
  static DimensionLabelPlacement? fromJson(Object? json) {
    if (json is! Map) return null;
    double? read(String key) {
      final value = json[key];
      return value is num && value.isFinite ? value.toDouble() : null;
    }

    final placement = DimensionLabelPlacement(
      offset: read('offset'),
      along: read('along'),
      angle: read('angle'),
      leg: read('leg'),
      radius: read('radius'),
    );
    return placement.isEmpty ? null : placement;
  }

  @override
  bool operator ==(Object other) =>
      other is DimensionLabelPlacement &&
      other.offset == offset &&
      other.along == along &&
      other.angle == angle &&
      other.leg == leg &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(offset, along, angle, leg, radius);

  @override
  String toString() => 'DimensionLabelPlacement(${toJson()})';
}
