/// The text a dimension label (and an edit field's pre-fill) shows for [value].
///
/// Always the magnitude: line-distance and point-line dimensions are signed
/// internally (the sign says which side of the line the dimension sits on),
/// but a minus sign on a label means nothing to the user. Callers add their
/// own `R` / `⌀` / `°` decoration.
String dimensionValueText(double value, {int decimals = 2}) => value.abs().toStringAsFixed(decimals);

/// The value to store when the user types [typed] over a dimension whose
/// current stored value is [existing].
///
/// The label hides the sign (see [dimensionValueText]), so a plain number keeps
/// the dimension on its current side and a leading minus flips it. A zero
/// [existing] value counts as positive.
double resolveDimensionSign(double typed, double existing) {
  final currentSign = existing < 0 ? -1.0 : 1.0;
  final flip = typed < 0 ? -1.0 : 1.0;
  return currentSign * flip * typed.abs();
}
