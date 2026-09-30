# S8 owner walkthrough - gizmo cues on the three reference mates

For the S8 exit criterion of `docs/constrained-drag-implementation-plan.md`. I could not drag a handle on a device, so this is
the checklist for you. Open the assembly, select a component, choose **Move/Rotate**. After a drag, the debug console prints one
line per release: `[PartScreen] constrained drag: requests=… anchors accepted=… rejected=… holds=… frames=… projection_us mean=… max=…
reanchors=… max_shown_step=…`. Numbers in brackets are what I measured against the real backend with a simulated hand (60 frames);
a real hand will differ, but the shape should match.

What to expect on every mated component: the Move/Rotate panel and the Assembly Tree panel show one line, e.g. `Group: 3 DOF`
(`- not grounded` if nothing in the group is fixed or linked to the focused part's own geometry). A handle the mates block is drawn
grey and short and cannot be grabbed; a partly free one is dimmed; a free one looks as before. An unmated component looks and behaves
exactly as before (no extra requests, no summary line).

## 1. Face mate (a block coincident with a plate's top face)

| Do | Expect | Drag log |
|---|---|---|
| Select the block, open Move/Rotate | Panel: `Group: 3 DOF`. Translate X and Y arrows normal; Z arrow grey/short. Rotate Z ring normal; X and Y rings grey/short. A small yellow square (the in-plane handle) between the X and Y arrows | - |
| Drag the yellow square around | Block slides in the face plane, follows the pointer exactly | requests ~1 + 1 per 150 ms + 1, shown step = hand step [8 requests, 0.500 / 0.500] |
| Drag the X arrow, release | Slides along X, stays on the face. Release = one request, one Undo entry | 0 rejected, 0 holds |
| Try to grab the Z arrow or a grey ring | Nothing is grabbed (orbit instead) | - |
| Rotate Z ring | Spins about the face normal | [max_shown_step = hand step] |

## 2. Concentric mate on an offset axis (a pin whose own origin is not on the pin's axis)

| Do | Expect | Drag log |
|---|---|---|
| Select the pin | Panel: `Group: 2 DOF`. The Z ring is **drawn on the pin's real axis** (not at the part's origin), full strength. Z arrow normal (slide along the axis); Y arrow dimmed; X arrow and X/Y rings grey | - |
| Drag the Z ring through ~90 deg | Pin swings about its real axis, following the hand with no lag or pops | requests ~8 per second of dragging; 0 rejected; **max_shown_step close to the hand's [0.472 vs hand 0.472; before S8 the ring sat on the origin and gave 0.489 vs 0.262]** |
| Drag the Z arrow | Slides along the pin axis only | - |

## 3. Angle mate (plate at a fixed angle to another face)

| Do | Expect | Drag log |
|---|---|---|
| Select the plate | Panel: `Group: 5 DOF`. All three translate arrows normal. Of the rings, the one about the locked direction is grey/short (which one depends on the current orientation); the others normal | - |
| Drag a normal ring | Plate turns, angle to the other face stays at the mate value | 0 rejected, 0 holds [max_shown_step 0.26 vs hand 0.26 for a spin about the cone axis] |
| Try the grey ring | Not grabbable | - |

## Also worth a look

* A component with **0 DOF** (mated fully or to a fixed part): no gizmo at all; the panel says `Fully constrained (0 DOF) …`.
* A mated group with **nothing fixed**: `Group: 6 DOF - not grounded`, all handles free; dragging moves the whole group.
* Drag into a wall repeatedly: the part holds still, and after 3 failed anchors "Can't follow that move" appears at most once a second.
* Anything that looks wrong on the cues (a handle the mates allow shown grey, or vice versa): tell me the mate type and the drag log line.
