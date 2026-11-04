# Harness self-test

`asm_pin_block/` is a zip's worth of JSON files for `asm_pin_block`, **written by hand, not by a model**: a block with a
d20 hole, a headed pin, and a `99_assembly.json` that places the pin and mates it by `add_component` `local_id` and
`face_selector` (a concentric mate and a seat mate). It exercises the external route's code (the importer, the part
cycle, the placement/mates split, the completeness check, the scorer) against a live backend without a model, and says
nothing about how a model or a chat app behaves.

```
mkdir -p tools/ai_eval/runs/asm_pin_block/selftest-ext-r1/files
cp tools/ai_eval/selftest/asm_pin_block/*.json tools/ai_eval/runs/asm_pin_block/selftest-ext-r1/files/
tools/ai_eval/eval.sh import tools/ai_eval/runs/asm_pin_block/selftest-ext-r1
```

Expected (2026-11-04): both parts built, `assembly_ok`, `mates` 2, `pass` true, `constrained` `2/2` (the pin free to
spin about z, which the key allows: `held|spin`). Deleting the `m_seat` mate from `99_assembly.json` leaves the pin free
to slide along z as well and scores `1/2` (`under`); an invalid `face_selector` direction (say `"+q"`) is refused by the
server with HTTP 422 and shows as `mates: validationFailed` with the placed assembly still built.

`asm_castor_sub/` (hand-written too): a bracket, an axle and a wheel-and-bush **sub-assembly** in one zip
(`"sub_assemblies"` in the manifest, `90_WHEEL_ASM.json`, and top-level mates into `castor/bush`). It has no key, so it is
not scored. Run it the same way, under `runs/asm_castor_sub/`. Expected (2026-11-04): 4 parts built, the sub-assembly
built with 2 mates, the assembly with 4, 4 solids, bbox 54 x 80 x 80, no overlap, and the completeness check showing
the bracket fixed and the castor and axle free only to spin about z (both declared).
