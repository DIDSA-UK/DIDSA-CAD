/// AI Modelling: manufacturing-process "add-on" text blocks a user can
/// toggle on in AI System Prompt Settings, each appended to the scoping
/// conversation's system prompt (`ai_scoping_prompt.dart`) when enabled.
///
/// These are prompt-guidance text only - none of them invoke a Feature type
/// this tool doesn't have (no Sheet Metal/Weldment/Casting Feature exists in
/// `backend/app/document`). Each one steers the AI's design choices and
/// clarifying questions within the existing plan schema, the same way a
/// human engineer would apply manufacturing-process judgement on top of an
/// otherwise ordinary block/revolve/sweep model.
library;

class AiPromptAddOn {
  final String label;
  final String text;

  const AiPromptAddOn({required this.label, required this.text});
}

/// Keyed by a stable id (persisted in `AiSystemPromptPreferences`) - never
/// rename a key once shipped, since a user's enabled set is stored as these
/// strings.
const Map<String, AiPromptAddOn> aiPromptAddOns = {
  'structural': AiPromptAddOn(
    label: 'Structural',
    text: '''
## Manufacturing/design context: Structural

This part carries real mechanical load. Prefer generous fillets at internal
corners and section transitions to reduce stress concentration. Ask about
the expected load path and magnitude if it isn't given and it would change
a dimension (a wall thickness, a rib, a fillet radius) rather than assuming
a value. Prefer ribs/gussets over simply thickening an entire wall when
reinforcing a span.''',
  ),
  'plastic': AiPromptAddOn(
    label: 'Plastic',
    text: '''
## Manufacturing/design context: Plastic

This part will be made from plastic (injection moulded or machined from
plastic stock). Prefer a roughly constant wall thickness - avoid one very
thick region next to a very thin one, which causes sink marks and warping.
Add a small fillet at internal corners rather than a sharp one (reduces
stress concentration and eases mould flow/machining alike). If a snap-fit,
living hinge, or boss/screw-post is implied, say so plainly and ask for the
detail needed rather than approximating it as a plain extrude.''',
  ),
  'casting': AiPromptAddOn(
    label: 'Casting',
    text: '''
## Manufacturing/design context: Casting

This part will be manufactured by casting. Avoid sharp internal
corners entirely - every internal edge should carry a generous fillet to
reduce stress concentration and aid mould release. Avoid very thin,
isolated wall sections (they cool/fill inconsistently) and abrupt thickness
transitions - taper between different wall thicknesses gradually. Prefer
rounded, organic transitions over sharp machined-looking features.''',
  ),
  'weldments': AiPromptAddOn(
    label: 'Weldments',
    text: '''
## Manufacturing/design context: Weldments

This part is a welded assembly of simpler stock shapes (plate, tube, angle,
bar), even though this tool only builds a single body. Model it as those
stock cross-sections extruded/swept and fused together, and call out where
two pieces meet as a weld joint in your reply text (not a schema field -
this tool has no dedicated Weldment feature). Prefer simple, constant
cross-sections over one complex sculpted body. Ask about plate/tube
thickness if it's implied but not stated, since it drives which stock size
is realistic.''',
  ),
  '3d_print': AiPromptAddOn(
    label: '3D Print',
    text: '''
## Manufacturing/design context: 3D Print

This part will be 3D printed (FDM/FFF). Avoid large unsupported overhangs
beyond roughly 45 degrees from vertical without noting in your reply that
support material will be needed. Avoid very thin walls below typical nozzle
width (about 0.8mm) - ask rather than silently rounding a thin dimension
up. Prefer designs that don't require internal support that can't be
removed after printing (an enclosed cavity with no access opening).''',
  ),
  'sheet_metal': AiPromptAddOn(
    label: 'Sheet Metal',
    text: '''
## Manufacturing/design context: Sheet Metal

This part will be manufactured from sheet metal. Prefer a constant wall
thickness throughout - do not vary extrude thickness within one part. Avoid
sharp internal corners on bent/formed edges - use a fillet at least equal
to the material thickness. Avoid deep, narrow slots or holes very close to
a bend line. Where the user doesn't specify thickness, ask rather than
guessing - sheet gauge tolerances matter more here than in solid
machining.''',
  ),
  'machining': AiPromptAddOn(
    label: 'Machining',
    text: '''
## Manufacturing/design context: Machining

This part will be CNC machined from solid stock. Prefer flat faces and
features reachable by a straight-line tool axis; avoid deep narrow internal
pockets or undercuts a standard end mill can't reach. A sharp internal
corner on a pocket is not physically achievable - the tool leaves a radius
at least equal to the cutter radius; do not model a perfectly sharp
internal corner where a fillet is more realistic. Prefer round holes over
odd internal cutout shapes where possible.''',
  ),
};
